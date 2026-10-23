//! Progressive (non-fragmented) MP4: the sample tables of a moov, and a plan
//! to deliver them as fragments of a few seconds cut at video keyframes.

use crate::bytes::{boxes, child, err, path, Reader, Result};
use crate::frag::{Sample, NOT_SYNC, SYNC};

/// How long a fragment runs before the next keyframe may start another.
const FRAGMENT_SECONDS: f64 = 2.0;

/// A sample with its absolute position in the file.
pub struct FileSample {
    pub dts: i64,
    pub cto: i64,
    pub duration: u32,
    pub sync: bool,
    pub offset: u64,
    pub size: u32,
}

impl FileSample {
    /// The sample with its data range relative to `base` in the file.
    pub fn at(&self, base: u64) -> Sample {
        let start = (self.offset - base) as usize;
        Sample {
            dts: self.dts,
            cto: self.cto,
            duration: self.duration,
            flags: if self.sync { SYNC } else { NOT_SYNC },
            data: start..start + self.size as usize,
        }
    }
}

/// Reads one trak's sample tables.
pub fn samples(trak: &[u8]) -> Result<Vec<FileSample>> {
    let Some(stbl) = path(trak, &[b"mdia", b"minf", b"stbl"])? else {
        return err("trak without stbl");
    };
    let sizes = sizes(stbl)?;
    let n = sizes.len();
    let mut out: Vec<FileSample> = Vec::with_capacity(n);

    let mut dts = 0i64;
    for (count, delta) in pairs(child(stbl, *b"stts")?)? {
        for _ in 0..count {
            out.push(FileSample { dts, cto: 0, duration: delta, sync: true, offset: 0, size: 0 });
            dts += i64::from(delta);
            if out.len() > n {
                return err("stts has more samples than stsz");
            }
        }
    }
    if out.len() != n {
        return err("stts and stsz disagree");
    }
    if let Some(ctts) = child(stbl, *b"ctts")? {
        let mut i = 0;
        for (count, offset) in pairs(Some(ctts))? {
            for _ in 0..count {
                if let Some(s) = out.get_mut(i) {
                    // Version 0 is unsigned on paper, but writers put negative
                    // offsets there too.
                    s.cto = i64::from(offset as i32);
                }
                i += 1;
            }
        }
    }
    if let Some(stss) = child(stbl, *b"stss")? {
        for s in &mut out {
            s.sync = false;
        }
        let mut r = Reader::new(stss);
        r.full_header()?;
        for _ in 0..r.u32()? {
            if let Some(s) = (r.u32()? as usize).checked_sub(1).and_then(|i| out.get_mut(i)) {
                s.sync = true;
            }
        }
    }
    for (s, size) in out.iter_mut().zip(&sizes) {
        s.size = *size;
    }
    place(stbl, &mut out)?;
    Ok(out)
}

fn pairs(data: Option<&[u8]>) -> Result<Vec<(u32, u32)>> {
    let Some(data) = data else {
        return err("missing sample table");
    };
    let mut r = Reader::new(data);
    r.full_header()?;
    let count = r.u32()? as usize;
    if count > r.remaining() / 8 {
        return err("truncated sample table");
    }
    (0..count).map(|_| Ok((r.u32()?, r.u32()?))).collect()
}

fn sizes(stbl: &[u8]) -> Result<Vec<u32>> {
    if let Some(stsz) = child(stbl, *b"stsz")? {
        let mut r = Reader::new(stsz);
        r.full_header()?;
        let fixed = r.u32()?;
        let count = r.u32()? as usize;
        if fixed != 0 {
            return Ok(vec![fixed; count]);
        }
        if count > r.remaining() / 4 {
            return err("truncated stsz");
        }
        return (0..count).map(|_| r.u32()).collect();
    }
    let Some(stz2) = child(stbl, *b"stz2")? else {
        return err("stbl without sample sizes");
    };
    let mut r = Reader::new(stz2);
    r.full_header()?;
    let bits = r.u32()? & 0xff;
    let count = r.u32()? as usize;
    let mut out = Vec::with_capacity(count.min(r.remaining() * 2));
    while out.len() < count {
        match bits {
            4 => {
                let b = r.u8()?;
                out.push(u32::from(b >> 4));
                if out.len() < count {
                    out.push(u32::from(b & 0xf));
                }
            }
            8 => out.push(u32::from(r.u8()?)),
            16 => out.push(u32::from(r.u16()?)),
            _ => return err("bad stz2 field size"),
        }
    }
    Ok(out)
}

/// Fills in file offsets from the chunk tables.
fn place(stbl: &[u8], samples: &mut [FileSample]) -> Result<()> {
    let mut chunks = Vec::new();
    if let Some(stco) = child(stbl, *b"stco")? {
        let mut r = Reader::new(stco);
        r.full_header()?;
        for _ in 0..r.u32()? {
            chunks.push(u64::from(r.u32()?));
        }
    } else if let Some(co64) = child(stbl, *b"co64")? {
        let mut r = Reader::new(co64);
        r.full_header()?;
        for _ in 0..r.u32()? {
            chunks.push(r.u64()?);
        }
    } else {
        return err("stbl without chunk offsets");
    }
    let runs = pairs_of_three(child(stbl, *b"stsc")?)?;
    let mut i = 0;
    for (n, first) in runs.iter().enumerate() {
        let last_chunk = runs.get(n + 1).map_or(chunks.len(), |next| next.0 as usize - 1);
        let first_chunk = (first.0 as usize).saturating_sub(1);
        for &chunk_offset in chunks.get(first_chunk..last_chunk.min(chunks.len())).unwrap_or_default() {
            let mut offset = chunk_offset;
            for _ in 0..first.1 {
                let Some(s) = samples.get_mut(i) else {
                    return Ok(());
                };
                s.offset = offset;
                offset += u64::from(s.size);
                i += 1;
            }
        }
    }
    if i < samples.len() {
        return err("chunk tables don't cover every sample");
    }
    Ok(())
}

fn pairs_of_three(data: Option<&[u8]>) -> Result<Vec<(u32, u32)>> {
    let Some(data) = data else {
        return err("stbl without stsc");
    };
    let mut r = Reader::new(data);
    r.full_header()?;
    let count = r.u32()? as usize;
    if count > r.remaining() / 12 {
        return err("truncated stsc");
    }
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let first = r.u32()?;
        let per_chunk = r.u32()?;
        r.u32()?;
        if first == 0 || out.last().is_some_and(|&(prev, _)| prev >= first) {
            return err("bad stsc");
        }
        out.push((first, per_chunk));
    }
    Ok(out)
}

/// Where each fragment ends, as a time in seconds: at the first video
/// keyframe at least `FRAGMENT_SECONDS` after the fragment's start, or every
/// `FRAGMENT_SECONDS` without video.
pub fn cut_times(video: Option<(&[FileSample], u32)>, end: f64) -> Vec<f64> {
    let mut cuts = Vec::new();
    let mut start = 0.0;
    if let Some((samples, timescale)) = video {
        for s in samples.iter().filter(|s| s.sync) {
            let t = s.dts as f64 / f64::from(timescale);
            if t - start >= FRAGMENT_SECONDS {
                cuts.push(t);
                start = t;
            }
        }
    } else {
        while start + FRAGMENT_SECONDS < end {
            start += FRAGMENT_SECONDS;
            cuts.push(start);
        }
    }
    cuts.push(f64::INFINITY);
    cuts
}

/// The top-level boxes of a file so far: the moov's range once it's all
/// there, or how far the scan got.
pub enum Scan {
    Moov(std::ops::Range<usize>),
    NeedMore,
}

pub fn find_moov(data: &[u8]) -> Result<Scan> {
    let mut pos = 0usize;
    loop {
        let Some(rest) = data.get(pos..) else {
            return Ok(Scan::NeedMore);
        };
        let Some((size, header)) = crate::bytes::box_extent(rest)? else {
            return Ok(Scan::NeedMore);
        };
        if rest.get(4..8) == Some(b"moov") {
            if size > rest.len() {
                return Ok(Scan::NeedMore);
            }
            return Ok(Scan::Moov(pos + header..pos + size));
        }
        pos = pos.saturating_add(size);
    }
}

/// The traks of a moov, by track id, for reading their tables.
pub fn traks(moov: &[u8]) -> Result<Vec<&[u8]>> {
    Ok(boxes(moov)?.into_iter().filter(|b| &b.kind == b"trak").map(|b| b.body).collect())
}
