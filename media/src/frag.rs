use std::ops::Range;

use crate::bytes::{boxes, err, Reader, Result, Writer};
use crate::init::Defaults;

pub const SYNC: u32 = 0x0200_0000;
pub const NOT_SYNC: u32 = 0x0101_0000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sample {
    pub dts: i64,
    pub cto: i64,
    pub duration: u32,
    pub flags: u32,
    pub data: Range<usize>,
}

impl Sample {
    pub fn pts(&self) -> i64 {
        self.dts.saturating_add(self.cto)
    }
}

pub struct Run {
    pub track_id: u32,
    pub samples: Vec<Sample>,
}

pub type TrackLookup<'a> = &'a dyn Fn(u32) -> Option<(Defaults, i64)>;

pub const MAX_SAMPLES: usize = 1 << 17;

pub fn parse_moof(unit: &[u8], lookup: TrackLookup<'_>) -> Result<Vec<Run>> {
    let Some(moof) = boxes(unit)?.into_iter().next().filter(|b| &b.kind == b"moof") else {
        return err("expected moof");
    };
    let mut runs = Vec::new();
    let mut data_end = 0usize;
    let mut budget = MAX_SAMPLES;
    for traf in boxes(moof.body)? {
        if &traf.kind != b"traf" {
            continue;
        }
        runs.push(parse_traf(traf.body, lookup, unit.len(), &mut data_end, &mut budget)?);
    }
    Ok(runs)
}

fn parse_traf(
    traf: &[u8],
    lookup: TrackLookup<'_>,
    unit_len: usize,
    data_end: &mut usize,
    budget: &mut usize,
) -> Result<Run> {
    let children = boxes(traf)?;
    let Some(tfhd) = children.iter().find(|b| &b.kind == b"tfhd") else {
        return err("traf without tfhd");
    };
    let mut r = Reader::new(tfhd.body);
    let (_, flags) = r.full_header()?;
    let track_id = r.u32()?;
    let Some((mut defaults, mut dts)) = lookup(track_id) else {
        return err(format!("fragment for unknown track {track_id}"));
    };
    if flags & 0x1 != 0 {
        return err("fragments must use moof-relative offsets");
    }
    if flags & 0x2 != 0 {
        r.u32()?;
    }
    if flags & 0x8 != 0 {
        defaults.duration = r.u32()?;
    }
    if flags & 0x10 != 0 {
        defaults.size = r.u32()?;
    }
    if flags & 0x20 != 0 {
        defaults.flags = r.u32()?;
    }
    let base = if flags & 0x20000 != 0 { 0 } else { *data_end };
    let mut pos = base;
    if let Some(tfdt) = children.iter().find(|b| &b.kind == b"tfdt") {
        let mut r = Reader::new(tfdt.body);
        let (version, _) = r.full_header()?;
        let t = if version == 1 { r.u64()? } else { u64::from(r.u32()?) };
        dts = i64::try_from(t).map_or_else(|_| err("tfdt out of range"), Ok)?;
    }
    let mut samples = Vec::new();
    for trun in children.iter().filter(|b| &b.kind == b"trun") {
        let mut r = Reader::new(trun.body);
        let (version, flags) = r.full_header()?;
        let count = r.u32()? as usize;
        if flags & 0x1 != 0 {
            let offset = i64::from(r.u32()? as i32);
            let start = i64::try_from(base).ok().and_then(|b| b.checked_add(offset));
            pos = start.and_then(|p| usize::try_from(p).ok()).map_or_else(|| err("data offset before the moof"), Ok)?;
        }
        let first_flags = if flags & 0x4 != 0 { Some(r.u32()?) } else { None };
        let per_sample = [0x100, 0x200, 0x400, 0x800].iter().filter(|&&f| flags & f != 0).count() * 4;
        if per_sample > 0 && count > r.remaining() / per_sample {
            return err("trun shorter than its sample count");
        }
        if count > *budget {
            return err("too many samples in one fragment");
        }
        *budget -= count;
        samples.reserve(count);
        for i in 0..count {
            let duration = if flags & 0x100 != 0 { r.u32()? } else { defaults.duration };
            let size = if flags & 0x200 != 0 { r.u32()? } else { defaults.size } as usize;
            let mut sample_flags = if flags & 0x400 != 0 { r.u32()? } else { defaults.flags };
            if i == 0 {
                sample_flags = first_flags.unwrap_or(sample_flags);
            }
            let cto = match flags & 0x800 {
                0 => 0,
                _ if version == 0 => i64::from(r.u32()?),
                _ => i64::from(r.u32()? as i32),
            };
            let end = pos.checked_add(size).filter(|&end| end <= unit_len);
            let Some(end) = end else {
                return err("sample data outside the mdat");
            };
            samples.push(Sample { dts, cto, duration, flags: sample_flags, data: pos..end });
            pos = end;
            dts = dts.checked_add(i64::from(duration)).map_or_else(|| err("timestamps out of range"), Ok)?;
        }
    }
    *data_end = pos;
    Ok(Run { track_id, samples })
}

pub struct OutSample {
    pub duration: u32,
    pub flags: u32,
    pub cto: i32,
    pub data: Vec<u8>,
}

pub struct OutTrack {
    pub id: u32,
    pub base_dts: u64,
    pub samples: Vec<OutSample>,
}

pub fn write_fragment(sequence: u32, tracks: &[OutTrack]) -> Vec<u8> {
    let mut w = Writer::new();
    w.begin(*b"moof");
    w.begin_full(*b"mfhd", 0, 0);
    w.u32(sequence);
    w.end();
    let mut offsets = Vec::new();
    for t in tracks.iter().filter(|t| !t.samples.is_empty()) {
        w.begin(*b"traf");
        w.begin_full(*b"tfhd", 0, 0x20000);
        w.u32(t.id);
        w.end();
        w.begin_full(*b"tfdt", 1, 0);
        w.u64(t.base_dts);
        w.end();
        w.begin_full(*b"trun", 1, 0xf01);
        w.u32(t.samples.len() as u32);
        offsets.push(w.len());
        w.u32(0);
        for s in &t.samples {
            w.u32(s.duration);
            w.u32(s.data.len() as u32);
            w.u32(s.flags);
            w.u32(s.cto as u32);
        }
        w.end();
        w.end();
    }
    w.end();
    let mut data_pos = w.len() + 8;
    for (t, at) in tracks.iter().filter(|t| !t.samples.is_empty()).zip(offsets) {
        w.set_u32(at, data_pos as u32);
        data_pos += t.samples.iter().map(|s| s.data.len()).sum::<usize>();
    }
    w.begin(*b"mdat");
    for t in tracks {
        for s in &t.samples {
            w.bytes(&s.data);
        }
    }
    w.end();
    w.buf
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_box(kind: [u8; 4], body: &[u8]) -> Vec<u8> {
        let mut out = u32::try_from(body.len() + 8).unwrap().to_be_bytes().to_vec();
        out.extend_from_slice(&kind);
        out.extend_from_slice(body);
        out
    }

    fn traf(track: u32, data_offset: i32) -> Vec<u8> {
        let mut tfhd = vec![0, 0, 0, 0];
        tfhd.extend_from_slice(&track.to_be_bytes());
        let mut trun = vec![0, 0, 0x02, 0x01];
        trun.extend_from_slice(&1u32.to_be_bytes());
        trun.extend_from_slice(&data_offset.to_be_bytes());
        trun.extend_from_slice(&4u32.to_be_bytes());
        [make_box(*b"tfhd", &tfhd), make_box(*b"trun", &trun)].concat()
    }

    #[test]
    fn trun_offsets_are_relative_to_the_traf_base() {
        let moof_len = 8 + 2 * (8 + 16 + 8 + 16);
        let first = i32::try_from(moof_len + 8).unwrap();
        let moof = make_box(*b"moof", &[make_box(*b"traf", &traf(1, first)), make_box(*b"traf", &traf(2, 4))].concat());
        assert_eq!(moof.len(), moof_len);
        let unit = [moof, make_box(*b"mdat", &[1, 1, 1, 1, 0, 0, 0, 0, 2, 2, 2, 2])].concat();
        let lookup = |_| Some((Defaults::default(), 0));
        let runs = parse_moof(&unit, &lookup).unwrap();
        let start = moof_len + 8;
        assert_eq!(runs[0].samples[0].data, start..start + 4);
        assert_eq!(runs[1].samples[0].data, start + 8..start + 12);
        assert_eq!(unit[runs[1].samples[0].data.clone()], [2, 2, 2, 2]);
    }
}
