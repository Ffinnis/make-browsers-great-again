use std::collections::{BTreeMap, HashMap, VecDeque};
use std::ops::Range;

use crate::bytes::{box_extent, err, Error, Reader, Result, Writer};
use crate::frag::{self, OutSample, OutTrack, Run, Sample, NOT_SYNC, SYNC};
use crate::init::{self, Codec, Track};
use crate::progressive::{self, Cuts, FileSample, Scan};

const MAX_GOP: usize = 1200;
const MAX_GOP_BYTES: usize = 32 << 20;

const STATE_VERSION: u32 = 2;

fn put_opt(w: &mut Writer, v: Option<i64>) {
    w.u8(u8::from(v.is_some()));
    w.u64(v.unwrap_or(0) as u64);
}

fn get_opt(r: &mut Reader<'_>) -> Result<Option<i64>> {
    let some = r.u8()? != 0;
    let v = r.u64()? as i64;
    Ok(some.then_some(v))
}

pub const MAX_INPUT: usize = 192 << 20;

const MAX_FRAMES: usize = 1 << 16;

pub const KEY: u32 = 1;
pub const DECODE_ONLY: u32 = 2;
pub const FLUSH: u32 = 4;
pub const FINISH: u32 = 8;

const SKIP_BOX: u64 = 1 << 20;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct JobSample {
    pub track: u32,
    pub flags: u32,
    pub offset: u32,
    pub len: u32,
    pub timestamp: f64,
    pub duration: f64,
    pub codec: u32,
    pub bitrate: u32,
}

pub const DROP: u32 = 0;
pub const ENCODE: u32 = 1;
pub const ENCODE_KEY: u32 = 2;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct HeldGroup {
    pub seq: f64,
    pub start: f64,
    pub end: f64,
    pub offset: u32,
    pub len: u32,
}

#[derive(Default)]
pub struct Job {
    pub samples: Vec<JobSample>,
    pub data: Vec<u8>,
    parts: Vec<OutTrack>,
}

#[derive(Default)]
pub struct Input {
    buf: Vec<u8>,
    start: usize,
    overflow: bool,
}

impl Input {
    pub fn data(&self) -> &[u8] {
        self.buf.get(self.start..).unwrap_or_default()
    }

    pub fn len(&self) -> usize {
        self.buf.len().saturating_sub(self.start)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn consume(&mut self, n: usize) {
        self.start = self.start.saturating_add(n).min(self.buf.len());
        if self.start == self.buf.len() {
            self.clear();
        }
    }

    fn clear(&mut self) {
        self.buf.clear();
        self.start = 0;
        if self.buf.capacity() > 16 << 20 {
            self.buf = Vec::new();
        }
    }

    pub fn room(&mut self, n: usize) -> Option<&mut Vec<u8>> {
        if self.len().checked_add(n).is_none_or(|total| total > MAX_INPUT) {
            self.overflow = true;
            return None;
        }
        if self.start > 0 && (self.start >= self.len() || self.buf.capacity() - self.buf.len() < n) {
            self.buf.drain(..self.start);
            self.start = 0;
        }
        self.buf.try_reserve(n).ok()?;
        Some(&mut self.buf)
    }

    pub fn buffer(&mut self) -> &mut Vec<u8> {
        &mut self.buf
    }
}

#[derive(Default)]
struct Gop {
    samples: Vec<(i64, u32, Range<usize>)>,
    data: Vec<u8>,
    lost: bool,
}

impl Gop {
    fn clear(&mut self) {
        self.samples.clear();
        self.data.clear();
        self.lost = false;
    }

    fn usable(&self) -> bool {
        !self.lost && !self.samples.is_empty()
    }

    fn add(&mut self, pts: i64, duration: u32, key: bool, bytes: &[u8]) {
        if key {
            self.clear();
        } else if self.lost || self.samples.is_empty() {
            self.lost = true;
            return;
        }
        if self.samples.len() >= MAX_GOP || self.data.len() + bytes.len() > MAX_GOP_BYTES {
            self.clear();
            self.lost = true;
            return;
        }
        let start = self.data.len();
        self.data.extend_from_slice(bytes);
        self.samples.push((pts, duration, start..self.data.len()));
    }
}

struct Stream {
    track: Track,
    next_dts: i64,
    end_dts: Option<i64>,
    gop: Gop,
    needs_key: bool,
    aligned: bool,
    run: u64,
    last_pts: Option<i64>,
    bytes: u64,
    ticks: u64,
}

struct Frame {
    pts: i64,
    duration: u32,
    epoch: u32,
    seq: f64,
    run: u64,
    key: bool,
    visible: (u16, u16),
}

struct Chunk {
    pts: i64,
    duration: u32,
    epoch: u32,
    seq: f64,
    key: bool,
    size: (u16, u16),
    visible: (u16, u16),
    data: Vec<u8>,
}

#[derive(Default)]
struct VideoOut {
    frames: BTreeMap<(u64, i64), Frame>,
    encoding: VecDeque<(i64, Frame)>,
    ready: Vec<Chunk>,
    main_epoch: u32,
    size: Option<(u16, u16)>,
    last_kept: Option<(u64, i64)>,
    natural: Option<(u32, u32)>,
}

impl VideoOut {
    fn has_hole(&self, run: u64) -> bool {
        let mut frames: Vec<(i64, u32)> =
            self.frames.values().filter(|f| f.run == run).map(|f| (f.pts, f.duration)).collect();
        frames.sort_unstable();
        frames.windows(2).any(|w| {
            let duration = i64::from(w[0].1);
            w[1].0.saturating_sub(w[0].0.saturating_add(duration)) > duration / 2
        })
    }

    fn stretch(&mut self, f: &Frame) -> bool {
        let Some((run, pts)) = self.last_kept.filter(|&(run, pts)| run == f.run && pts < f.pts) else {
            return false;
        };
        let Ok(duration) = u32::try_from(f.pts.saturating_add(i64::from(f.duration)).saturating_sub(pts)) else {
            return false;
        };
        let _ = run;
        if let Some((_, g)) = self.encoding.iter_mut().rev().find(|(_, g)| g.pts == pts && g.run == f.run) {
            g.duration = g.duration.max(duration);
            return true;
        }
        if let Some(c) = self.ready.last_mut().filter(|c| c.pts == pts) {
            c.duration = c.duration.max(duration);
            return true;
        }
        false
    }

    fn trim(&mut self) {
        if self.frames.len() > MAX_FRAMES {
            let last = self.frames.values().map(|f| f.run).max().unwrap_or(0);
            self.frames.retain(|_, f| f.run == last);
        }
    }
}

struct Table {
    samples: Vec<FileSample>,
    keep: Vec<u64>,
    done: usize,
}

struct Progressive {
    tables: Vec<Table>,
    cuts: Cuts,
    cut: Option<f64>,
    last_cut: f64,
}

impl Progressive {
    fn closed() -> Self {
        Progressive { tables: Vec::new(), cuts: Cuts::new(None, 0.0), cut: None, last_cut: 0.0 }
    }

    fn finished(&self) -> bool {
        self.tables.iter().all(|t| t.done >= t.samples.len())
    }
}

#[derive(Default)]
pub struct Converter {
    progressive: bool,
    pub input: Input,
    streams: Vec<Stream>,
    moov: Vec<u8>,
    moov_progressive: bool,
    sequence: u32,
    job: Option<Job>,
    prog: Option<Progressive>,
    video: HashMap<u32, VideoOut>,
    epoch: u32,
    seq: f64,
    pub output: Vec<u8>,
    pub held: Vec<u8>,
    pub held_groups: Vec<HeldGroup>,
    pub inits_out: u32,
    pub state: Vec<u8>,
    pub chunk_buffer: Vec<u8>,
    pub error: String,
    pub mime: String,
    pub init: Vec<u8>,
    pub init_generation: u32,
    ftyp: Vec<u8>,
    out_ftyp: Vec<u8>,
    out_init: Vec<u8>,
    reinit: bool,
    reinit_done: [bool; 2],
    pending_ftyp: Option<Vec<u8>>,
    finishing: Option<usize>,
    pub output_range: Option<(f64, f64)>,
    pub natural_out: Option<Natural>,
    seek: Seek,
    pub need: Option<u64>,
}

#[derive(Default)]
struct Seek {
    base: u64,
    start: f64,
    awaiting: Option<u64>,
    offsets: bool,
    skip_to: u64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Natural {
    pub width: u32,
    pub height: u32,
    pub at: Option<f64>,
    pub seq: f64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Poll {
    Idle,
    Job,
}

impl Converter {
    pub fn new(progressive: bool) -> Self {
        Converter { progressive, ..Self::default() }
    }

    pub fn begin(&mut self, seq: f64) {
        if self.reinit_done.iter().any(|&d| d) {
            self.reinit = false;
        }
        self.reinit_done = [false; 2];
        self.epoch = self.epoch.wrapping_add(1);
        self.seq = seq;
    }

    pub fn wants_input(&self) -> bool {
        self.prog.as_ref().is_none_or(|p| !p.finished())
    }

    pub fn clear_output(&mut self) {
        for buf in [&mut self.output, &mut self.held] {
            buf.clear();
            if buf.capacity() > 16 << 20 {
                *buf = Vec::new();
            }
        }
        self.held_groups.clear();
        self.inits_out = 0;
        self.output_range = None;
        self.natural_out = None;
        self.need = None;
    }

    pub fn discard_output(&mut self) {
        let need = self.seek.awaiting;
        self.clear_output();
        self.need = need;
        if !self.out_init.is_empty() {
            self.reinit = true;
            self.reinit_done = [false; 2];
        }
        self.forget_natural();
    }

    fn forget_natural(&mut self) {
        for v in self.video.values_mut() {
            v.natural = None;
        }
    }

    pub fn set_start(&mut self, seconds: f64) {
        if seconds.is_finite() && seconds > 0.0 {
            self.seek.start = seconds;
        }
    }

    pub fn offset(&mut self, offset: u64) -> bool {
        self.seek.offsets = true;
        if !self.wants_input() || !self.progressive {
            return true;
        }
        let want = self.seek.awaiting.unwrap_or(self.seek.base + self.input.len() as u64);
        if offset != want {
            return false;
        }
        if self.seek.awaiting.take().is_some() && offset != self.seek.base + self.input.len() as u64 {
            self.input.clear();
            self.seek.base = offset;
        }
        true
    }

    fn request(&mut self, offset: u64) {
        let have = self.seek.base + self.input.len() as u64;
        if (self.seek.base..=have).contains(&offset) {
            let n = (offset - self.seek.base) as usize;
            self.input.consume(n);
            self.seek.base = offset;
            return;
        }
        if self.seek.offsets {
            if self.seek.awaiting != Some(offset) {
                self.seek.awaiting = Some(offset);
                self.need = Some(offset);
            }
            self.input.clear();
        } else if offset > have {
            self.seek.skip_to = offset;
            self.input.clear();
            self.seek.base = have;
        }
    }

    pub fn natural(&self) -> Option<(u32, u32)> {
        self.streams.iter().find(|s| s.track.is_video()).and_then(|s| s.track.natural())
    }

    pub fn push(&mut self, bytes: &[u8]) {
        if !self.wants_input() {
            return;
        }
        if let Some(buf) = self.input.room(bytes.len()) {
            buf.extend_from_slice(bytes);
            self.committed(bytes.len());
        }
    }

    pub fn committed(&mut self, len: usize) {
        if !self.wants_input() {
            let buf = self.input.buffer();
            buf.truncate(buf.len().saturating_sub(len));
        } else if self.seek.skip_to > self.seek.base {
            let n = (self.seek.skip_to - self.seek.base).min(self.input.len() as u64);
            self.input.consume(n as usize);
            self.seek.base += n;
        }
    }

    pub fn poll(&mut self) -> Result<Poll> {
        if self.job.is_some() {
            return Ok(Poll::Job);
        }
        if self.input.overflow {
            self.input.overflow = false;
            self.input.clear();
            self.prog = None;
            return err("too much input at once");
        }
        if !self.progressive {
            return self.poll_fragmented();
        }
        let r = self.poll_progressive();
        if r.is_err() {
            self.input.clear();
            self.prog = Some(Progressive::closed());
        }
        r
    }

    pub fn job(&self) -> Option<&Job> {
        self.job.as_ref()
    }

    pub fn chunk(&mut self, track: u32, timestamp: f64, key: bool, size: (u16, u16), data: Vec<u8>) -> Result<()> {
        if !timestamp.is_finite() {
            return err("chunk without a timestamp");
        }
        let Some(v) = self.video.get_mut(&track) else {
            return Ok(());
        };
        let ts = timestamp.round() as i64;
        let Some(f) = v.encoding.iter().position(|(t, _)| *t == ts).and_then(|i| v.encoding.remove(i)).map(|(_, f)| f)
        else {
            return Ok(());
        };
        v.ready.push(Chunk {
            pts: f.pts,
            duration: f.duration,
            epoch: f.epoch,
            seq: f.seq,
            key,
            size,
            visible: f.visible,
            data,
        });
        Ok(())
    }

    pub fn frame(&mut self, track: u32, timestamp: f64, skip: bool, visible: (u16, u16)) -> u32 {
        let Some(v) = self.video.get_mut(&track) else {
            return DROP;
        };
        if !timestamp.is_finite() {
            return DROP;
        }
        let ts = timestamp.round() as i64;
        let mut found = None;
        let mut next = v.frames.keys().next().map(|k| k.0);
        while let Some(run) = next {
            if v.frames.contains_key(&(run, ts)) {
                found = Some(run);
                break;
            }
            next = v.frames.range((run.saturating_add(1), i64::MIN)..).next().map(|(k, _)| k.0).filter(|&r| r > run);
        }
        let Some(mut f) = found.and_then(|run| v.frames.remove(&(run, ts))) else {
            return DROP;
        };
        f.visible = visible;
        v.frames = v.frames.split_off(&(f.run, ts));
        if skip && !f.key && v.stretch(&f) {
            return DROP;
        }
        if v.encoding.len() >= MAX_FRAMES {
            v.encoding.clear();
        }
        let key = f.key;
        v.last_kept = Some((f.run, f.pts));
        v.encoding.push_back((ts, f));
        if key {
            ENCODE_KEY
        } else {
            ENCODE
        }
    }

    pub fn flushed(&mut self, track: u32) {
        for s in self.streams.iter_mut().filter(|s| s.track.id == track) {
            s.needs_key = true;
        }
        if let Some(v) = self.video.get_mut(&track) {
            v.frames.clear();
            v.encoding.clear();
            v.last_kept = None;
        }
    }

    pub fn restart(&mut self) {
        self.job = None;
        for s in &mut self.streams {
            s.needs_key = true;
        }
        for v in self.video.values_mut() {
            v.frames.clear();
            v.encoding.clear();
            v.ready.clear();
            v.last_kept = None;
        }
    }

    pub fn write(&mut self) -> Result<()> {
        let parts = self.job.take().map(|j| j.parts).unwrap_or_default();
        self.write_parts(parts)
    }

    pub fn reset(&mut self) {
        self.input.clear();
        self.input.overflow = false;
        self.job = None;
        self.prog = None;
        self.finishing = None;
        self.seek = Seek { start: self.seek.start, offsets: self.seek.offsets, ..Seek::default() };
        for s in &mut self.streams {
            s.gop.clear();
            s.needs_key = true;
            s.end_dts = None;
            if let Codec::Aac(a) = &mut s.track.codec {
                a.reset();
            }
        }
        for v in self.video.values_mut() {
            v.frames.clear();
            v.encoding.clear();
            v.ready.clear();
            v.last_kept = None;
        }
        self.reinit = !self.out_init.is_empty();
        self.forget_natural();
    }

    pub fn recyclable(&self) -> bool {
        !self.progressive
            && self.prog.is_none()
            && self.job.is_none()
            && self.input.is_empty()
            && !self.init.is_empty()
            && self.video.values().all(|v| v.frames.is_empty() && v.encoding.is_empty() && v.ready.is_empty())
            && self.streams.iter().all(|s| match &s.track.codec {
                Codec::Aac(a) => a.fresh(),
                _ => true,
            })
    }

    pub fn save_state(&mut self) {
        let mut w = Writer::new();
        w.u32(STATE_VERSION);
        w.u32(self.epoch);
        w.u32(self.sequence);
        w.u32(self.streams.len() as u32);
        for s in &self.streams {
            w.u32(s.track.id);
            w.u64(s.next_dts as u64);
            put_opt(&mut w, s.end_dts);
            w.u8(u8::from(s.needs_key));
            w.u8(u8::from(s.aligned));
            w.u64(s.run);
            put_opt(&mut w, s.last_pts);
            w.u64(s.bytes);
            w.u64(s.ticks);
            w.u8(u8::from(s.gop.lost));
            w.u32(s.gop.samples.len() as u32);
            for (pts, duration, range) in &s.gop.samples {
                w.u64(*pts as u64);
                w.u32(*duration);
                w.u32(range.len() as u32);
            }
            w.bytes(&s.gop.data);
            let v = self.video.get(&s.track.id);
            w.u32(v.map_or(0, |v| v.main_epoch));
            let size = v.and_then(|v| v.size);
            w.u8(u8::from(size.is_some()));
            let (width, height) = size.unwrap_or_default();
            w.u16(width);
            w.u16(height);
            let natural = v.and_then(|v| v.natural);
            w.u8(u8::from(natural.is_some()));
            let (width, height) = natural.unwrap_or_default();
            w.u32(width);
            w.u32(height);
        }
        self.state = w.buf;
    }

    pub fn load_state(&mut self, state: &[u8]) -> Result<()> {
        let mut r = Reader::new(state);
        if r.u32()? != STATE_VERSION {
            return err("state from another version");
        }
        let epoch = r.u32()?;
        let sequence = r.u32()?;
        if r.u32()? as usize != self.streams.len() {
            return err("state for other tracks");
        }
        let mut loaded = Vec::with_capacity(self.streams.len());
        for s in &self.streams {
            if r.u32()? != s.track.id {
                return err("state for other tracks");
            }
            let next_dts = r.u64()? as i64;
            let end_dts = get_opt(&mut r)?;
            let needs_key = r.u8()? != 0;
            let aligned = r.u8()? != 0;
            let run = r.u64()?;
            let last_pts = get_opt(&mut r)?;
            let (bytes, ticks) = (r.u64()?, r.u64()?);
            let mut gop = Gop { lost: r.u8()? != 0, ..Gop::default() };
            let count = r.u32()? as usize;
            if count > MAX_GOP || count > r.remaining() / 16 {
                return err("bad state");
            }
            let mut total = 0usize;
            for _ in 0..count {
                let pts = r.u64()? as i64;
                let duration = r.u32()?;
                let len = r.u32()? as usize;
                gop.samples.push((pts, duration, total..total + len));
                total += len;
            }
            gop.data = r.bytes(total)?.to_vec();
            let main_epoch = r.u32()?;
            let has_size = r.u8()? != 0;
            let size = (r.u16()?, r.u16()?);
            let has_natural = r.u8()? != 0;
            let natural = (r.u32()?, r.u32()?);
            loaded.push((
                next_dts,
                end_dts,
                needs_key,
                aligned,
                run,
                last_pts,
                bytes,
                ticks,
                gop,
                main_epoch,
                has_size.then_some(size),
                has_natural.then_some(natural),
            ));
        }
        for (s, l) in self.streams.iter_mut().zip(loaded) {
            let (next_dts, end_dts, needs_key, aligned, run, last_pts, bytes, ticks, gop, main_epoch, size, natural) =
                l;
            s.next_dts = next_dts;
            s.end_dts = end_dts;
            s.needs_key = needs_key;
            s.aligned = aligned;
            s.run = run;
            s.last_pts = last_pts;
            s.bytes = bytes;
            s.ticks = ticks;
            s.gop = gop;
            if s.track.is_video() {
                let v = self.video.entry(s.track.id).or_default();
                v.main_epoch = main_epoch;
                v.size = size;
                v.natural = natural.or(v.natural);
            }
        }
        self.epoch = epoch;
        self.sequence = sequence;
        Ok(())
    }

    pub fn fail(&mut self, e: &Error) {
        self.error.clone_from(&e.0);
    }

    fn emit(&mut self, held: bool, bytes: &[u8], is_init: bool) {
        let i = usize::from(held);
        let buf = if held { &mut self.held } else { &mut self.output };
        if self.reinit && !self.reinit_done[i] {
            if !is_init {
                buf.extend_from_slice(&self.out_init);
                self.inits_out += 1;
            }
            self.reinit_done[i] = true;
        }
        if is_init && bytes.get(4..8) == Some(b"moov") {
            self.inits_out += 1;
        }
        buf.extend_from_slice(bytes);
    }

    fn write_fragment(&mut self, held: bool, tracks: &[OutTrack]) {
        if tracks.iter().any(|t| !t.samples.is_empty()) {
            if !held {
                for t in tracks {
                    if let Some((start, end)) = self.time_range(t) {
                        let (a, b) = self.output_range.unwrap_or((start, end));
                        self.output_range = Some((a.min(start), b.max(end)));
                    }
                }
            }
            self.sequence = self.sequence.wrapping_add(1);
            let bytes = frag::write_fragment(self.sequence, tracks);
            self.emit(held, &bytes, false);
        }
    }

    fn seconds(&self, id: u32, ticks: i64) -> f64 {
        let (timescale, edit) =
            self.streams.iter().find(|s| s.track.id == id).map_or((1, 0), |s| (s.track.timescale, s.track.edit_offset));
        ticks.saturating_sub(edit) as f64 / f64::from(timescale.max(1))
    }

    fn time_range(&self, t: &OutTrack) -> Option<(f64, f64)> {
        let mut dts = i64::try_from(t.base_dts).ok()?;
        let (mut start, mut end) = (i64::MAX, i64::MIN);
        for s in &t.samples {
            let pts = dts.saturating_add(i64::from(s.cto));
            start = start.min(pts);
            end = end.max(pts.saturating_add(i64::from(s.duration)));
            dts = dts.saturating_add(i64::from(s.duration));
        }
        (start <= end).then(|| (self.seconds(t.id, start), self.seconds(t.id, end)))
    }

    fn write_init(&mut self, held: bool) -> Result<()> {
        if let Some(ftyp) = self.pending_ftyp.take() {
            self.emit(held, &ftyp, true);
        }
        let tracks: Vec<&Track> = self.streams.iter().map(|s| &s.track).collect();
        let video = &self.video;
        let moov =
            init::write_moov(&self.moov, &tracks, self.moov_progressive, &|id| video.get(&id).and_then(|v| v.size))?;
        self.out_init.clone_from(&self.out_ftyp);
        self.out_init.extend_from_slice(&moov);
        self.emit(held, &moov, true);
        if self.video.values().all(|v| v.natural.is_none()) {
            let first = self.streams.iter().find(|s| s.track.is_video()).map(|s| (s.track.id, s.track.natural()));
            if let Some((id, Some((width, height)))) = first {
                self.natural_out = Some(Natural { width, height, at: None, seq: self.seq });
                self.video.entry(id).or_default().natural = Some((width, height));
            }
        }
        Ok(())
    }

    fn write_parts(&mut self, mut parts: Vec<OutTrack>) -> Result<()> {
        let mut ids: Vec<u32> = self.video.keys().copied().collect();
        ids.sort_unstable();
        for id in ids {
            let Some(v) = self.video.get_mut(&id) else {
                continue;
            };
            let mut ready = std::mem::take(&mut v.ready);
            let held =
                if v.main_epoch == self.epoch { 0 } else { ready.iter().take_while(|c| c.epoch != self.epoch).count() };
            if held < ready.len() {
                v.main_epoch = self.epoch;
            }
            let main = ready.split_off(held);
            let mut rest = ready;
            while let Some(first) = rest.first() {
                let epoch = first.epoch;
                let n = rest.iter().take_while(|c| c.epoch == epoch).count();
                let tail = rest.split_off(n);
                let group = std::mem::replace(&mut rest, tail);
                self.write_held(id, group)?;
            }
            self.write_video(id, main, false, &mut parts)?;
        }
        self.write_fragment(false, &parts);
        Ok(())
    }

    fn write_held(&mut self, id: u32, chunks: Vec<Chunk>) -> Result<()> {
        let Some(first) = chunks.first() else {
            return Ok(());
        };
        let seq = first.seq;
        let start = self.seconds(id, chunks.iter().map(|c| c.pts).min().unwrap_or(0));
        let end =
            self.seconds(id, chunks.iter().map(|c| c.pts.saturating_add(i64::from(c.duration))).max().unwrap_or(0));
        let at = self.held.len();
        self.write_video(id, chunks, true, &mut Vec::new())?;
        let len = self.held.len() - at;
        if len == 0 {
            return Ok(());
        }
        match self.held_groups.last_mut() {
            Some(g) if g.seq.to_bits() == seq.to_bits() && g.offset as usize + g.len as usize == at => {
                g.len += len as u32;
                g.start = g.start.min(start);
                g.end = g.end.max(end);
            }
            _ => self.held_groups.push(HeldGroup { seq, start, end, offset: at as u32, len: len as u32 }),
        }
        Ok(())
    }

    fn write_video(&mut self, id: u32, chunks: Vec<Chunk>, held: bool, parts: &mut Vec<OutTrack>) -> Result<()> {
        let source = self.streams.iter().find(|s| s.track.id == id).and_then(|s| s.track.size());
        let mut current = self.video.get(&id).and_then(|v| v.size).or(source);
        let mut run: Vec<(i64, OutSample)> = Vec::new();
        for c in chunks {
            if c.pts < 0 {
                continue;
            }
            if c.key && Some(c.size) != current {
                self.flush_run(id, &mut run, held, parts);
                current = Some(c.size);
                if let Some(v) = self.video.get_mut(&id) {
                    v.size = (Some(c.size) != source).then_some(c.size);
                }
                self.write_init(held)?;
            }
            if let Some((pts, last)) = run.last_mut() {
                let gap = c.pts - *pts;
                if gap == 0 {
                    continue;
                }
                if gap > 0 && gap <= i64::from(last.duration.max(1)) * 4 {
                    last.duration = u32::try_from(gap).unwrap_or(u32::MAX);
                } else {
                    self.flush_run(id, &mut run, held, parts);
                }
            }
            self.note_natural(id, &c, source);
            let flags = if c.key { SYNC } else { NOT_SYNC };
            run.push((c.pts, OutSample { duration: c.duration.max(1), flags, cto: 0, data: c.data }));
        }
        self.flush_run(id, &mut run, held, parts);
        Ok(())
    }

    fn note_natural(&mut self, id: u32, c: &Chunk, source: Option<(u16, u16)>) {
        let visible = if c.visible.0 > 0 && c.visible.1 > 0 { Some(c.visible) } else { source };
        let natural = visible.and_then(|size| self.streams.iter().find(|s| s.track.id == id)?.track.natural_for(size));
        let Some((width, height)) = natural else {
            return;
        };
        let again = self.video.values().all(|v| v.natural.is_none());
        let at = (!again).then(|| self.seconds(id, c.pts));
        let Some(v) = self.video.get_mut(&id) else {
            return;
        };
        if v.natural != Some((width, height)) {
            v.natural = Some((width, height));
            self.natural_out = Some(Natural { width, height, at, seq: c.seq });
        }
    }

    fn flush_run(&mut self, id: u32, run: &mut Vec<(i64, OutSample)>, held: bool, parts: &mut Vec<OutTrack>) {
        let Some(&(base, _)) = run.first() else {
            return;
        };
        let samples = run.drain(..).map(|(_, s)| s).collect();
        let mut tracks = std::mem::take(parts);
        tracks.push(OutTrack { id, base_dts: base as u64, samples });
        tracks.sort_by_key(|t| t.id);
        self.write_fragment(held, &tracks);
    }

    fn poll_fragmented(&mut self) -> Result<Poll> {
        loop {
            let data = self.input.data();
            let (size, header) = match box_extent(data) {
                Ok(Some(extent)) => extent,
                Ok(None) => return Ok(Poll::Idle),
                Err(e) => {
                    self.input.clear();
                    return Err(e);
                }
            };
            if size > MAX_INPUT {
                self.input.clear();
                return err("box too large");
            }
            if size > data.len() {
                return Ok(Poll::Idle);
            }
            let kind: [u8; 4] = [data[4], data[5], data[6], data[7]];
            if &kind == b"moof" {
                let rest = &data[size..];
                let Some((mdat_size, _)) = box_extent(rest)? else {
                    return Ok(Poll::Idle);
                };
                if rest.get(4..8) != Some(b"mdat") {
                    self.input.consume(size);
                    return err("moof not followed by mdat");
                }
                if mdat_size > MAX_INPUT - size {
                    self.input.clear();
                    return err("fragment too large");
                }
                if mdat_size > rest.len() {
                    return Ok(Poll::Idle);
                }
                let end = size + mdat_size;
                let input = std::mem::take(&mut self.input);
                let r = self.fragment(&input.data()[..end]);
                self.input = input;
                self.input.consume(end);
                if r? {
                    return Ok(Poll::Job);
                }
                continue;
            }
            if &kind == b"moov" {
                let changed = self.streams.is_empty() || data.get(header..size) != Some(&self.moov[..]);
                if changed && self.finishing != Some(size) {
                    if let Some(job) = self.finish_job() {
                        self.job = Some(job);
                        self.finishing = Some(size);
                        return Ok(Poll::Job);
                    }
                }
                self.finishing = None;
            }
            let data = self.input.data();
            let bytes = data[..size].to_vec();
            self.input.consume(size);
            match &kind {
                b"ftyp" => {
                    self.pending_ftyp = Some(bytes.clone());
                    self.out_ftyp.clone_from(&bytes);
                    self.ftyp = bytes;
                }
                b"moov" => self.open_init(&bytes, header)?,
                _ => {}
            }
        }
    }

    fn finish_job(&self) -> Option<Job> {
        let mut job = Job::default();
        for s in &self.streams {
            let Codec::Avc(avc) = &s.track.codec else {
                continue;
            };
            if self.video.get(&s.track.id).is_some_and(|v| !v.frames.is_empty() || !v.encoding.is_empty()) {
                job.samples.push(JobSample {
                    track: s.track.id,
                    flags: FINISH | FLUSH,
                    offset: 0,
                    len: 0,
                    timestamp: 0.0,
                    duration: 0.0,
                    codec: avc.codec_word(),
                    bitrate: s.bitrate(),
                });
            }
        }
        (!job.samples.is_empty()).then_some(job)
    }

    fn open_init(&mut self, moov: &[u8], header: usize) -> Result<()> {
        let body = &moov[header..];
        let tracks = init::parse_moov(body)?;
        let mime = init::mime(&tracks);
        if body != self.moov || self.streams.is_empty() {
            self.write_parts(Vec::new())?;
            let run = self.streams.iter().map(|s| s.run).max().unwrap_or(0);
            for t in tracks.iter().filter(|t| t.is_video()) {
                let v = self.video.entry(t.id).or_default();
                v.size = None;
                v.last_kept = None;
            }
            self.streams = tracks
                .into_iter()
                .map(|t| {
                    let mut s = Stream::new(t);
                    s.run = run;
                    s
                })
                .collect();
            self.moov = body.to_vec();
        }
        self.mime = mime;
        self.moov_progressive = false;
        self.write_init(false)?;
        self.reinit = false;
        self.init.clone_from(&self.ftyp);
        self.init.extend_from_slice(moov);
        self.init_generation = self.init_generation.wrapping_add(1);
        Ok(())
    }

    fn fragment(&mut self, unit: &[u8]) -> Result<bool> {
        if self.streams.is_empty() {
            return err("media segment before an init segment");
        }
        let lookup = |id: u32| self.streams.iter().find(|s| s.track.id == id).map(|s| (s.track.defaults, s.next_dts));
        let runs = frag::parse_moof(unit, &lookup)?;
        self.convert_runs(runs, unit, &[])
    }

    fn convert_runs(&mut self, runs: Vec<Run>, data: &[u8], next_key: &[(u32, bool)]) -> Result<bool> {
        let mut job = Job::default();
        let (epoch, seq) = (self.epoch, self.seq);
        for run in runs {
            let Some(stream) = self.streams.iter_mut().find(|s| s.track.id == run.track_id) else {
                continue;
            };
            if let Some(last) = run.samples.last() {
                stream.next_dts = last.dts.saturating_add(i64::from(last.duration));
            }
            if stream.track.is_video() {
                let out = self.video.entry(stream.track.id).or_default();
                let next_key = next_key.iter().find(|(id, _)| *id == run.track_id).map(|&(_, key)| key);
                stream.video(&run.samples, data, &mut job, out, (epoch, seq), next_key)?;
                out.trim();
            } else {
                job.parts.push(stream.convert(&run.samples, data)?);
            }
        }
        if !job.samples.is_empty() {
            self.job = Some(job);
            return Ok(true);
        }
        self.write_parts(job.parts)?;
        Ok(false)
    }

    fn poll_progressive(&mut self) -> Result<Poll> {
        loop {
            if self.prog.is_none() && !self.open_progressive()? {
                if self.input.len() >= MAX_INPUT {
                    return err("no moov in the file's first 192 MB");
                }
                return if self.progressive { Ok(Poll::Idle) } else { self.poll_fragmented() };
            }
            let Some(prog) = self.prog.as_mut() else {
                return Ok(Poll::Idle);
            };
            if prog.finished() || self.seek.awaiting.is_some() {
                return Ok(Poll::Idle);
            }
            let have = self.seek.base + self.input.len() as u64;
            let cut = if let Some(cut) = prog.cut {
                cut
            } else {
                let first = self
                    .streams
                    .iter()
                    .zip(&prog.tables)
                    .filter_map(|(s, t)| t.samples.get(t.done).map(|x| x.dts as f64 / f64::from(s.track.timescale)))
                    .fold(f64::INFINITY, f64::min);
                let cut = prog.cuts.next(prog.last_cut.max(first));
                prog.cut = Some(cut);
                cut
            };
            let mut picks = Vec::new();
            for (stream, t) in self.streams.iter().zip(&prog.tables) {
                let timescale = f64::from(stream.track.timescale);
                let n = t.samples[t.done..].iter().take_while(|s| (s.dts as f64 / timescale) < cut).count();
                let end = t.samples[t.done..t.done + n].iter().map(FileSample::end).max().unwrap_or(0);
                if end == u64::MAX {
                    return err("sample past the end of any file");
                }
                if end > have {
                    if self.input.len() >= MAX_INPUT {
                        return err("file isn't interleaved enough to stream");
                    }
                    return Ok(Poll::Idle);
                }
                picks.push(n);
            }
            let base = self.seek.base;
            let len = self.input.len();
            let mut runs = Vec::new();
            let mut next_key = Vec::new();
            for ((stream, t), n) in self.streams.iter().zip(&mut prog.tables).zip(picks) {
                let samples =
                    t.samples[t.done..t.done + n].iter().map(|s| s.at(base, len)).collect::<Result<Vec<Sample>>>()?;
                t.done += n;
                runs.push(Run { track_id: stream.track.id, samples });
                next_key.push((stream.track.id, t.samples.get(t.done).is_none_or(|s| s.sync)));
            }
            prog.cut = None;
            prog.last_cut = cut;
            let keep_from = prog.tables.iter().filter_map(|t| t.keep.get(t.done).copied()).min();
            let input = std::mem::take(&mut self.input);
            let became_job = self.convert_runs(runs, input.data(), &next_key);
            self.input = input;
            if self.prog.is_some() {
                let drop = keep_from.map_or(self.input.len() as u64, |k| k.saturating_sub(self.seek.base));
                let drop = drop.min(self.input.len() as u64);
                self.input.consume(drop as usize);
                self.seek.base += drop;
            }
            if became_job? {
                return Ok(Poll::Job);
            }
        }
    }

    fn open_progressive(&mut self) -> Result<bool> {
        let range = match progressive::find_moov(self.input.data())? {
            Scan::Moov(range) => range,
            Scan::NeedMore(Some(end)) if self.seek.offsets && end > self.input.len() as u64 + SKIP_BOX => {
                self.request(self.seek.base.saturating_add(end));
                return Ok(false);
            }
            Scan::NeedMore(_) => return Ok(false),
        };
        let moov = self.input.data()[range].to_vec();
        if crate::bytes::child(&moov, *b"mvex")?.is_some() {
            self.progressive = false;
            return Ok(false);
        }
        let mut tracks = Vec::new();
        let mut tables = Vec::new();
        for (track, trak) in init::parse_progressive(&moov)? {
            let samples = progressive::samples(trak)?;
            let keep = progressive::suffix_min_offsets(&samples);
            tables.push(Table { samples, keep, done: 0 });
            tracks.push(track);
        }
        if self.seek.start > 0.0 {
            start_at(self.seek.start, &tracks, &mut tables);
        }
        let end = tracks
            .iter()
            .zip(&tables)
            .map(|(t, s)| s.samples.last().map_or(0.0, |s| s.end_time() / f64::from(t.timescale)))
            .fold(0.0, f64::max);
        let video = tracks.iter().zip(&tables).find(|(t, _)| t.is_video()).map(|(t, s)| (&s.samples[..], t.timescale));
        let cuts = Cuts::new(video, end);
        let mut ftyp = Writer::new();
        ftyp.begin(*b"ftyp");
        ftyp.bytes(b"iso6");
        ftyp.u32(0);
        ftyp.bytes(b"iso6mp41");
        ftyp.end();
        self.emit(false, &ftyp.buf, true);
        self.out_ftyp = ftyp.buf;
        self.mime = init::mime(&tracks);
        self.streams = tracks.into_iter().map(Stream::new).collect();
        self.moov = moov;
        self.moov_progressive = true;
        self.write_init(false)?;
        self.reinit = false;
        let need = tables.iter().filter_map(|t| t.keep.get(t.done).copied()).min();
        self.prog = Some(Progressive { tables, cuts, cut: None, last_cut: 0.0 });
        if let Some(need) = need {
            self.request(need);
        }
        Ok(true)
    }
}

fn start_at(start: f64, tracks: &[Track], tables: &mut [Table]) {
    let seconds = |t: &Track, ticks: i64| ticks.saturating_sub(t.edit_offset) as f64 / f64::from(t.timescale);
    let video = tracks.iter().zip(tables.iter()).find(|(t, _)| t.is_video());
    let from = match video {
        Some((t, table)) => table
            .samples
            .iter()
            .filter(|s| s.sync)
            .map(|s| seconds(t, s.dts.saturating_add(s.cto)))
            .filter(|&at| at <= start)
            .fold(f64::NEG_INFINITY, f64::max),
        None => start,
    };
    if !from.is_finite() {
        return;
    }
    for (t, table) in tracks.iter().zip(tables.iter_mut()) {
        table.done = if t.is_video() {
            let key = table.samples.iter().position(|s| s.sync && seconds(t, s.dts.saturating_add(s.cto)) >= from);
            key.unwrap_or(0)
        } else {
            let playing = table
                .samples
                .iter()
                .position(|s| seconds(t, s.dts.saturating_add(s.cto).saturating_add(i64::from(s.duration))) > from);
            playing.unwrap_or(table.samples.len()).saturating_sub(1)
        };
    }
}

impl Stream {
    fn new(track: Track) -> Self {
        Stream {
            track,
            next_dts: 0,
            end_dts: None,
            gop: Gop::default(),
            needs_key: true,
            aligned: true,
            run: 0,
            last_pts: None,
            bytes: 0,
            ticks: 0,
        }
    }

    fn convert(&mut self, samples: &[Sample], data: &[u8]) -> Result<OutTrack> {
        let id = self.track.id;
        let base_dts = samples.first().map_or(0, |s| s.dts.max(0) as u64);
        let mut out = Vec::with_capacity(samples.len());
        for s in samples {
            let Some(bytes) = data.get(s.data.clone()) else {
                return err("sample data outside the input");
            };
            if let Codec::Aac(conv) = &mut self.track.codec {
                let flac = conv.convert(bytes, s.dts);
                out.push(OutSample { duration: s.duration, flags: SYNC, cto: 0, data: flac });
            } else {
                let cto = i32::try_from(s.cto).map_or_else(|_| err("composition offset out of range"), Ok)?;
                out.push(OutSample { duration: s.duration, flags: s.flags, cto, data: bytes.to_vec() });
            }
        }
        Ok(OutTrack { id, base_dts, samples: out })
    }

    fn video(
        &mut self,
        samples: &[Sample],
        data: &[u8],
        job: &mut Job,
        out: &mut VideoOut,
        (epoch, seq): (u32, f64),
        next_key: Option<bool>,
    ) -> Result<()> {
        let Codec::Avc(avc) = &self.track.codec else {
            return err("not video");
        };
        let Some(first) = samples.first() else {
            return Ok(());
        };
        let continues = self.end_dts == Some(first.dts);
        self.end_dts = samples.last().map(|s| s.dts.saturating_add(i64::from(s.duration)));
        let mut converted = Vec::with_capacity(samples.len());
        for s in samples {
            let Some(bytes) = data.get(s.data.clone()) else {
                return err("sample data outside the input");
            };
            let start = job.data.len();
            let key = avc.to_annex_b(bytes, &mut job.data)?;
            converted.push((key, start..job.data.len()));
            self.bytes += bytes.len() as u64;
            self.ticks += u64::from(s.duration);
        }
        let codec = avc.codec_word();
        let timescale = self.track.timescale;
        if samples.iter().any(|s| micros(s.pts(), timescale).unsigned_abs() > 1 << 53) {
            return err("timestamps out of range");
        }
        let bitrate = self.bitrate();
        let push = |job: &mut Job, flags: u32, pts: i64, duration: u32, bytes: Range<usize>| {
            job.samples.push(JobSample {
                track: self.track.id,
                flags,
                offset: bytes.start as u32,
                len: bytes.len() as u32,
                timestamp: micros(pts, timescale) as f64,
                duration: micros(i64::from(duration), timescale) as f64,
                codec,
                bitrate,
            });
        };

        let starts_with_key = converted[0].0;
        if continues && !starts_with_key {
            self.aligned = false;
        }
        let (start, replay, new_run) = if starts_with_key {
            (0, false, self.needs_key || !continues)
        } else if continues && !self.needs_key {
            (0, false, false)
        } else if continues && self.gop.usable() {
            (0, true, true)
        } else {
            (converted.iter().position(|c| c.0).unwrap_or(converted.len()), false, true)
        };
        if new_run {
            self.run = self.run.wrapping_add(1);
        }
        if replay {
            for (i, (pts, duration, range)) in self.gop.samples.iter().enumerate() {
                let at = job.data.len();
                job.data.extend_from_slice(&self.gop.data[range.clone()]);
                let flags = if i == 0 { KEY | DECODE_ONLY } else { DECODE_ONLY };
                push(job, flags, *pts, *duration, at..job.data.len());
            }
        }
        if !continues {
            self.last_pts = None;
        }
        let floor = if replay { self.last_pts } else { None };
        let mut flags = Vec::with_capacity(samples.len());
        for (s, (key, _)) in samples.iter().zip(&converted).skip(start) {
            let key = if *key { KEY } else { 0 };
            if floor.is_some_and(|floor| s.pts() < floor) {
                flags.push(key | DECODE_ONLY);
                continue;
            }
            flags.push(key);
            let frame =
                Frame { pts: s.pts(), duration: s.duration, epoch, seq, run: self.run, key: key != 0, visible: (0, 0) };
            out.frames.insert((self.run, micros(s.pts(), timescale)), frame);
            self.last_pts = Some(self.last_pts.map_or(s.pts(), |last| last.max(s.pts())));
        }
        let flush = next_key.unwrap_or(self.aligned) && !out.has_hole(self.run);
        let flush = if flush { FLUSH } else { 0 };
        for ((s, (_, range)), flags) in samples.iter().zip(&converted).skip(start).zip(flags) {
            push(job, flush | flags, s.pts(), s.duration, range.clone());
        }
        if start < samples.len() {
            self.needs_key = false;
        }
        if !continues {
            self.gop.clear();
        }
        for (s, (key, range)) in samples.iter().zip(converted) {
            self.gop.add(s.pts(), s.duration, key, &job.data[range]);
        }
        Ok(())
    }

    fn bitrate(&self) -> u32 {
        let seconds = self.ticks as f64 / f64::from(self.track.timescale);
        if seconds <= 0.0 {
            return 1_000_000;
        }
        (self.bytes as f64 * 8.0 / seconds).clamp(100_000.0, 40_000_000.0) as u32
    }
}

fn micros(ticks: i64, timescale: u32) -> i64 {
    let ts = i128::from(timescale.max(1));
    let us = (i128::from(ticks) * 1_000_000 + ts / 2).div_euclid(ts);
    i64::try_from(us).unwrap_or(if us < 0 { i64::MIN } else { i64::MAX })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn job_samples_are_40_bytes() {
        assert_eq!(size_of::<JobSample>(), 40);
    }

    #[test]
    fn input_reuses_its_buffer() {
        let mut input = Input::default();
        input.room(4).unwrap().extend_from_slice(&[1, 2, 3, 4]);
        input.consume(3);
        assert_eq!(input.data(), [4]);
        input.room(2).unwrap().extend_from_slice(&[5, 6]);
        assert_eq!(input.data(), [4, 5, 6]);
        input.consume(3);
        assert!(input.is_empty());
        assert!(input.room(MAX_INPUT + 1).is_none());
    }
}
