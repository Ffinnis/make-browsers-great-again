//! Progressive (non-fragmented) MP4: the sample tables of a moov, and a plan
//! to deliver them as fragments of a couple of seconds.

use crate::bytes::{child, err, path, Reader, Result};
use crate::frag::{Sample, NOT_SYNC, SYNC};

/// How long a fragment runs. The worker's decoder carries on from one
/// fragment to the next, so cuts needn't wait for keyframes, but one at
/// most `KEYFRAME_SLACK` later is taken instead.
const FRAGMENT_SECONDS: f64 = 2.0;
const KEYFRAME_SLACK: f64 = 1.0;

/// The most samples a track may have: over four hours of 60 fps video or
/// six of AAC. Sample tables are tiny next to what they describe, so this
/// bounds what a small, broken moov can make the converter allocate.
pub const MAX_SAMPLES: usize = 1 << 20;

/// Past any real file: 256 TB.
const MAX_OFFSET: u64 = 1 << 48;

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
    /// When the sample ends, in its track's timescale.
    pub fn end_time(&self) -> f64 {
        (self.dts + i64::from(self.duration)) as f64
    }

    /// Where the sample's bytes end in the file.
    pub fn end(&self) -> u64 {
        // Offsets are checked when the tables are read.
        self.offset.saturating_add(u64::from(self.size))
    }

    /// The sample with its data range relative to `base` in the file, if
    /// its bytes lie within the `len` bytes there.
    pub fn at(&self, base: u64, len: usize) -> Result<Sample> {
        let start = self.offset.checked_sub(base).and_then(|s| usize::try_from(s).ok());
        let range = start.and_then(|start| Some(start..start.checked_add(self.size as usize)?));
        match range {
            Some(data) if data.end <= len => Ok(Sample {
                dts: self.dts,
                cto: self.cto,
                duration: self.duration,
                flags: if self.sync { SYNC } else { NOT_SYNC },
                data,
            }),
            _ => err("sample outside the file's bytes"),
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
        let mut rest = &mut out[..];
        for (count, offset) in pairs(Some(ctts))? {
            let (these, after) = rest.split_at_mut((count as usize).min(rest.len()));
            for s in these {
                // Version 0 is unsigned on paper, but writers put negative
                // offsets there too.
                s.cto = i64::from(offset as i32);
            }
            rest = after;
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
        if count > MAX_SAMPLES {
            return err("too many samples");
        }
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
    if count > MAX_SAMPLES {
        return err("too many samples");
    }
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
                if offset > MAX_OFFSET {
                    return err("chunk past the end of any file");
                }
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

/// Where each fragment ends, as a decode time in seconds: every
/// `FRAGMENT_SECONDS`, moved to a video keyframe if one comes within
/// `KEYFRAME_SLACK` after that, so that fragments start on keyframes where
/// the file allows and sparse keyframes don't make one huge fragment.
///
/// Planned one fragment at a time from where the samples still to go out
/// start, so a span without samples (a sample whose duration claims years)
/// is skipped rather than cut into two-second pieces, and every fragment
/// takes at least one sample: the work is bounded by the sample count.
pub struct Cuts {
    /// Video keyframes' decode times in seconds, in order.
    keys: Vec<f64>,
    next_key: usize,
    /// Where the file's last sample ends.
    end: f64,
}

impl Cuts {
    pub fn new(video: Option<(&[FileSample], u32)>, end: f64) -> Self {
        let keys = video.map_or_else(Vec::new, |(samples, timescale)| {
            samples.iter().filter(|s| s.sync).map(|s| s.dts as f64 / f64::from(timescale)).collect()
        });
        Cuts { keys, next_key: 0, end }
    }

    /// The end of the fragment after `start`, the decode time of the first
    /// sample still to go out.
    pub fn next(&mut self, start: f64) -> f64 {
        let due = start + FRAGMENT_SECONDS;
        // The last fragment runs longer rather than leave a short one after it.
        if self.end - due <= KEYFRAME_SLACK || !due.is_finite() {
            return f64::INFINITY;
        }
        while self.keys.get(self.next_key).is_some_and(|&k| k < due) {
            self.next_key += 1;
        }
        self.keys.get(self.next_key).copied().filter(|&k| k <= due + KEYFRAME_SLACK).unwrap_or(due)
    }
}

/// For each sample, the lowest file offset of it and every sample after
/// it: where the bytes still needed start, without rescanning the table.
pub fn suffix_min_offsets(samples: &[FileSample]) -> Vec<u64> {
    let mut out = vec![0; samples.len()];
    let mut min = u64::MAX;
    for (i, s) in samples.iter().enumerate().rev() {
        min = min.min(s.offset);
        out[i] = min;
    }
    out
}

/// The top-level boxes of a file so far: the moov's range once it's all
/// there, or how far the scan got: where the box that isn't all there yet
/// ends, if it's known and isn't the moov.
pub enum Scan {
    Moov(std::ops::Range<usize>),
    NeedMore(Option<u64>),
}

pub fn find_moov(data: &[u8]) -> Result<Scan> {
    let mut pos = 0usize;
    loop {
        let Some(rest) = data.get(pos..) else {
            return Ok(Scan::NeedMore(None));
        };
        let Some((size, header)) = crate::bytes::box_extent(rest)? else {
            return Ok(Scan::NeedMore(None));
        };
        if rest.get(4..8) == Some(b"moov") {
            if size > rest.len() {
                return Ok(Scan::NeedMore(None));
            }
            return Ok(Scan::Moov(pos + header..pos + size));
        }
        if size > rest.len() {
            return Ok(Scan::NeedMore(Some(pos as u64 + size as u64)));
        }
        pos = pos.saturating_add(size);
    }
}

#[cfg(test)]
#[allow(clippy::float_cmp)]
mod tests {
    use super::*;

    fn sample(dts: i64, sync: bool, offset: u64) -> FileSample {
        FileSample { dts, cto: 0, duration: 1, sync, offset, size: 1 }
    }

    #[test]
    fn cuts_follow_keyframes_within_the_slack() {
        // Keyframes every 2.5 s at timescale 10.
        let samples: Vec<FileSample> = (0..100).map(|i| sample(i, i % 25 == 0, 0)).collect();
        let mut cuts = Cuts::new(Some((&samples, 10)), 10.0);
        assert_eq!(cuts.next(0.0), 2.5);
        assert_eq!(cuts.next(2.5), 5.0);
        assert_eq!(cuts.next(5.0), 7.5);
        // Less than the slack would be left after the next one.
        assert_eq!(cuts.next(7.5), f64::INFINITY);
    }

    #[test]
    fn a_sample_lasting_years_makes_one_cut_not_billions() {
        let mut cuts = Cuts::new(None, f64::from(u32::MAX));
        assert_eq!(cuts.next(0.0), 2.0);
        assert_eq!(cuts.next(1e9), 1e9 + 2.0);
    }

    #[test]
    fn suffix_minima() {
        let samples: Vec<FileSample> = [5, 3, 9, 4, 8].iter().map(|&o| sample(0, true, o)).collect();
        assert_eq!(suffix_min_offsets(&samples), [3, 3, 4, 4, 8]);
    }
}
