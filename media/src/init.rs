//! The init segment: reading tracks out of a moov, and writing the moov the
//! engine gets instead, with VP9 and FLAC sample entries in place of H.264
//! and AAC. Everything else, edit lists included, is copied as it is, so the
//! engine lays the converted samples on the same timeline as the originals.

use crate::audio::AacToFlac;
use crate::avc::AvcConfig;
use crate::bytes::{boxes, child, err, path, Mp4Box, Reader, Result, Writer};

pub enum Codec {
    Avc(AvcConfig),
    Aac(Box<AacToFlac>),
    /// Passed through untouched.
    Other,
}

/// Sample values a fragment leaves out (trex).
#[derive(Debug, Clone, Copy, Default)]
pub struct Defaults {
    pub duration: u32,
    pub size: u32,
    pub flags: u32,
}

pub struct Track {
    pub id: u32,
    pub timescale: u32,
    pub codec: Codec,
    pub defaults: Defaults,
    /// The original sample description, for tracks that pass through and
    /// for building the converted one.
    entry: Vec<u8>,
    entry_kind: [u8; 4],
}

impl Track {
    pub fn is_video(&self) -> bool {
        matches!(self.codec, Codec::Avc(_))
    }

    /// The codec as the engine sees it after conversion, for MIME types.
    pub fn output_codec(&self) -> String {
        match self.codec {
            Codec::Avc(_) => "vp09.00.41.08".into(),
            Codec::Aac(_) => "flac".into(),
            Codec::Other => String::from_utf8_lossy(&self.entry_kind).trim().to_lowercase(),
        }
    }

    fn visual(&self) -> bool {
        matches!(&self.entry_kind, b"avc1" | b"avc3" | b"vp09" | b"av01" | b"hvc1" | b"hev1")
    }

    /// The coded size in the sample entry, for a visual track.
    pub fn size(&self) -> Option<(u16, u16)> {
        let at = self.entry.get(8 + 24..8 + 28)?;
        Some((u16::from_be_bytes([at[0], at[1]]), u16::from_be_bytes([at[2], at[3]])))
    }
}

/// The tracks a moov describes, in order.
pub fn parse_moov(moov: &[u8]) -> Result<Vec<Track>> {
    let tracks = parse_traks(moov)?;
    if tracks.is_empty() {
        return err("moov has no tracks");
    }
    Ok(tracks)
}

/// The tracks of a progressive file worth delivering: video and audio the
/// engine can play once converted, and Opus and FLAC, which it plays as
/// they are. Timecode, metadata and text tracks (iPhone movies have them),
/// and audio that can't be converted (MP3, AC-3), are left out, so the
/// rest still plays. Video that can't be converted fails the file: playing
/// its sound alone would pass for a picture that never shows up.
pub fn parse_progressive(moov: &[u8]) -> Result<Vec<(Track, &[u8])>> {
    let mut out = Vec::new();
    let mut lost_video = false;
    for b in boxes(moov)? {
        if &b.kind != b"trak" {
            continue;
        }
        let handler = handler(b.body)?;
        if !matches!(&handler, b"vide" | b"soun") {
            continue;
        }
        let keep = match parse_trak(b.body) {
            Ok(track) => match (&track.codec, &track.entry_kind) {
                (Codec::Avc(_) | Codec::Aac(_), _) | (Codec::Other, b"Opus" | b"fLaC") => Some(track),
                _ => None,
            },
            Err(_) => None,
        };
        match keep {
            Some(track) => out.push((track, b.body)),
            None => lost_video |= &handler == b"vide",
        }
    }
    if lost_video && !out.iter().any(|(t, _)| t.is_video()) {
        return err("no H.264 video");
    }
    if out.is_empty() {
        return err("no H.264 or AAC track");
    }
    Ok(out)
}

fn handler(trak: &[u8]) -> Result<[u8; 4]> {
    let Some(hdlr) = path(trak, &[b"mdia", b"hdlr"])? else {
        return Ok([0; 4]);
    };
    let mut r = Reader::new(hdlr);
    r.full_header()?;
    r.u32()?;
    let b = r.bytes(4)?;
    Ok([b[0], b[1], b[2], b[3]])
}

fn parse_traks(moov: &[u8]) -> Result<Vec<Track>> {
    let mut defaults = Vec::new();
    if let Some(mvex) = child(moov, *b"mvex")? {
        for b in boxes(mvex)? {
            if &b.kind == b"trex" {
                let mut r = Reader::new(b.body);
                r.full_header()?;
                let id = r.u32()?;
                r.u32()?;
                let d = Defaults { duration: r.u32()?, size: r.u32()?, flags: r.u32()? };
                defaults.push((id, d));
            }
        }
    }
    let mut tracks = Vec::new();
    for b in boxes(moov)? {
        if &b.kind == b"trak" {
            let mut track = parse_trak(b.body)?;
            if let Some((_, d)) = defaults.iter().find(|(id, _)| *id == track.id) {
                track.defaults = *d;
            }
            tracks.push(track);
        }
    }
    Ok(tracks)
}

fn track_id(trak: &[u8]) -> Result<u32> {
    let Some(tkhd) = child(trak, *b"tkhd")? else {
        return err("trak without tkhd");
    };
    let mut r = Reader::new(tkhd);
    let (version, _) = r.full_header()?;
    r.skip(if version == 1 { 16 } else { 8 })?;
    r.u32()
}

fn parse_trak(trak: &[u8]) -> Result<Track> {
    let id = track_id(trak)?;
    let Some(mdhd) = path(trak, &[b"mdia", b"mdhd"])? else {
        return err("trak without mdhd");
    };
    let mut r = Reader::new(mdhd);
    let (version, _) = r.full_header()?;
    r.skip(if version == 1 { 16 } else { 8 })?;
    let timescale = r.u32()?;
    if timescale == 0 {
        return err("track with a zero timescale");
    }
    let Some(stsd) = path(trak, &[b"mdia", b"minf", b"stbl", b"stsd"])? else {
        return err("trak without stsd");
    };
    let mut r = Reader::new(stsd);
    r.full_header()?;
    let count = r.u32()?;
    let entries = boxes(r.rest())?;
    let Some(entry) = entries.first() else {
        return err("stsd without entries");
    };
    if count > 1 && entries.iter().any(|e| e.kind != entry.kind) {
        return err("tracks that change codec midway aren't supported");
    }
    let codec = match &entry.kind {
        b"avc1" | b"avc3" => {
            let Some(avcc) = child(entry.body.get(78..).unwrap_or_default(), *b"avcC")? else {
                return err("avc1 without avcC");
            };
            Codec::Avc(AvcConfig::parse(avcc)?)
        }
        b"mp4a" => Codec::Aac(Box::new(AacToFlac::new(&mp4a_config(entry.body)?, timescale)?)),
        _ => Codec::Other,
    };
    let mut raw = Writer::new();
    raw.boxed(entry.kind, entry.body);
    Ok(Track { id, timescale, codec, defaults: Defaults::default(), entry: raw.buf, entry_kind: entry.kind })
}

/// The `AudioSpecificConfig` inside an mp4a entry's esds.
fn mp4a_config(entry: &[u8]) -> Result<Vec<u8>> {
    let mut r = Reader::new(entry);
    r.skip(8)?;
    // QuickTime sound descriptions grow with their version.
    let extra = match r.u16()? {
        1 => 16,
        2 => 36,
        _ => 0,
    };
    let Some(children) = entry.get(28 + extra..) else {
        return err("truncated mp4a");
    };
    // QuickTime puts it inside a wave box.
    let esds = match child(children, *b"esds")? {
        Some(esds) => Some(esds),
        None => child(children, *b"wave")?.map(|wave| child(wave, *b"esds")).transpose()?.flatten(),
    };
    let Some(esds) = esds else {
        return err("mp4a without esds");
    };
    let mut r = Reader::new(esds);
    r.full_header()?;
    while r.remaining() > 0 {
        let tag = r.u8()?;
        let mut len = 0usize;
        for _ in 0..4 {
            let b = r.u8()?;
            len = len << 7 | usize::from(b & 0x7f);
            if b & 0x80 == 0 {
                break;
            }
        }
        match tag {
            // ES_Descriptor: ID, then flags saying which optional fields follow.
            3 => {
                r.u16()?;
                let flags = r.u8()?;
                if flags & 0x80 != 0 {
                    r.u16()?;
                }
                if flags & 0x40 != 0 {
                    let n = r.u8()?;
                    r.skip(usize::from(n))?;
                }
                if flags & 0x20 != 0 {
                    r.u16()?;
                }
            }
            // DecoderConfigDescriptor: only MPEG-4 and MPEG-2 AAC convert.
            4 => {
                let object = r.u8()?;
                if !matches!(object, 0x40 | 0x66..=0x68) {
                    return err(format!("mp4a object type {object:#x} isn't AAC"));
                }
                r.skip(12)?;
            }
            5 => return Ok(r.bytes(len)?.to_vec()),
            _ => r.skip(len)?,
        }
    }
    err("esds without AudioSpecificConfig")
}

/// The moov the engine gets, with the traks of `tracks` only. A progressive
/// file's moov also loses its sample tables and gains an mvex, since its
/// samples arrive as fragments. `size` gives a video track's coded size
/// once the encoder's differs from the input's.
pub fn write_moov(
    moov: &[u8],
    tracks: &[&Track],
    progressive: bool,
    size: &dyn Fn(u32) -> Option<(u16, u16)>,
) -> Result<Vec<u8>> {
    let mut w = Writer::new();
    w.begin(*b"moov");
    for b in boxes(moov)? {
        match &b.kind {
            b"trak" => {
                let id = track_id(b.body)?;
                let Some(track) = tracks.iter().find(|t| t.id == id) else {
                    continue;
                };
                let size = size(id);
                rewrite(&mut w, &b, 0, &mut |w, b| match &b.kind {
                    b"mdia" | b"minf" | b"stbl" => Ok(false),
                    b"stsd" => {
                        write_stsd(w, track, size)?;
                        Ok(true)
                    }
                    kind if progressive && is_sample_table(*kind) => {
                        write_empty_table(w, *kind);
                        Ok(true)
                    }
                    _ => {
                        w.boxed(b.kind, b.body);
                        Ok(true)
                    }
                })?;
            }
            b"mvex" if progressive => {}
            _ => w.boxed(b.kind, b.body),
        }
    }
    if progressive {
        w.begin(*b"mvex");
        for t in tracks {
            w.begin_full(*b"trex", 0, 0);
            w.u32(t.id);
            w.u32(1);
            w.u32(0);
            w.u32(0);
            w.u32(0);
            w.end();
        }
        w.end();
    }
    w.end();
    Ok(w.buf)
}

/// Copies a container box, letting `f` write any child itself (returning
/// true) or have it descended into (false). trak, mdia, minf, stbl is as
/// deep as a moov goes; boxes nested deeper than that are broken input.
fn rewrite(
    w: &mut Writer,
    b: &Mp4Box<'_>,
    depth: usize,
    f: &mut dyn FnMut(&mut Writer, &Mp4Box<'_>) -> Result<bool>,
) -> Result<()> {
    if depth > 4 {
        return err("boxes nested too deep");
    }
    w.begin(b.kind);
    for c in boxes(b.body)? {
        if !f(w, &c)? {
            rewrite(w, &c, depth + 1, f)?;
        }
    }
    w.end();
    Ok(())
}

fn is_sample_table(kind: [u8; 4]) -> bool {
    matches!(
        &kind,
        b"stts"
            | b"stsc"
            | b"stco"
            | b"co64"
            | b"stsz"
            | b"stz2"
            | b"ctts"
            | b"stss"
            | b"sdtp"
            | b"sbgp"
            | b"sgpd"
            | b"cslg"
            | b"stps"
            | b"subs"
            | b"saiz"
            | b"saio"
    )
}

/// Sample tables for a track whose samples all live in fragments. Boxes
/// other than the required ones are dropped: their entries would be wrong.
fn write_empty_table(w: &mut Writer, kind: [u8; 4]) {
    match &kind {
        b"stts" | b"stsc" | b"stco" | b"co64" => {
            w.begin_full(if &kind == b"co64" { *b"stco" } else { kind }, 0, 0);
            w.u32(0);
            w.end();
        }
        b"stsz" | b"stz2" => {
            w.begin_full(*b"stsz", 0, 0);
            w.u32(0);
            w.u32(0);
            w.end();
        }
        _ => {}
    }
}

fn write_stsd(w: &mut Writer, track: &Track, size: Option<(u16, u16)>) -> Result<()> {
    w.begin_full(*b"stsd", 0, 0);
    w.u32(1);
    let entry = boxes(&track.entry)?;
    let Some(entry) = entry.first() else {
        return err("missing sample entry");
    };
    match &track.codec {
        Codec::Avc(_) => write_vp09(w, entry.body, size)?,
        Codec::Aac(conv) => {
            w.begin(*b"fLaC");
            w.bytes(&[0; 6]);
            w.u16(1);
            w.bytes(&[0; 8]);
            w.u16(conv.config.channels as u16);
            w.u16(crate::flac::BITS as u16);
            w.u32(0);
            w.u32(if conv.config.rate > 0xffff { 0 } else { conv.config.rate << 16 });
            w.begin_full(*b"dfLa", 0, 0);
            w.bytes(&conv.dfla());
            w.end();
            w.end();
        }
        Codec::Other => w.bytes(&track.entry),
    }
    w.end();
    Ok(())
}

/// A vp09 entry with the avc1's pixel aspect, and its colour description if
/// it had one, and its size unless the encoder scaled the frames. The track
/// header keeps the input's size, which is what the page sees as the
/// video's size either way.
fn write_vp09(w: &mut Writer, avc1: &[u8], size: Option<(u16, u16)>) -> Result<()> {
    let Some(header) = avc1.get(..78) else {
        return err("truncated avc1");
    };
    let children = boxes(&avc1[78..])?;
    w.begin(*b"vp09");
    match size {
        Some((width, height)) => {
            w.bytes(&header[..24]);
            w.u16(width);
            w.u16(height);
            w.bytes(&header[28..]);
        }
        None => w.bytes(header),
    }
    // Unspecified, unless colr says otherwise.
    let (mut primaries, mut transfer, mut matrix, mut full) = (2u8, 2u8, 2u8, 0u8);
    for c in &children {
        if &c.kind == b"colr" && c.body.get(..4) == Some(b"nclx") {
            let mut r = Reader::new(&c.body[4..]);
            primaries = r.u16()? as u8;
            transfer = r.u16()? as u8;
            matrix = r.u16()? as u8;
            full = r.u8()? >> 7;
        }
    }
    w.begin_full(*b"vpcC", 1, 0);
    // Profile 0, level 4.1, 8-bit 4:2:0 (colocated), matching vp09.00.41.08.
    w.u8(0);
    w.u8(41);
    w.u8(8 << 4 | 1 << 1 | full);
    w.u8(primaries);
    w.u8(transfer);
    w.u8(matrix);
    w.u16(0);
    w.end();
    for c in children {
        if matches!(&c.kind, b"pasp" | b"colr") {
            w.boxed(c.kind, c.body);
        }
    }
    w.end();
    Ok(())
}

/// The MIME type the converted init needs, such as
/// `video/mp4; codecs="vp09.00.41.08,flac"`.
pub fn mime(tracks: &[Track]) -> String {
    let kind = if tracks.iter().any(Track::visual) { "video" } else { "audio" };
    let codecs: Vec<String> = tracks.iter().map(Track::output_codec).collect();
    format!("{kind}/mp4; codecs=\"{}\"", codecs.join(","))
}
