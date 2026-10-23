//! One converter per `SourceBuffer`: takes the bytes the page appends, and
//! gives back init segments and fragments the engine can play.
//!
//! Video needs the engine's codecs, so a fragment with H.264 in it becomes a
//! job: its samples as Annex-B, which the worker feeds to a `VideoDecoder`
//! that carries on from one job to the next. Every frame the decoder puts
//! out is encoded to VP9 and its chunk handed back here, and `write` puts
//! the chunks so far into fragments. A decoder holds its last few frames
//! until more input pushes them out, so a fragment's last frames can come
//! out in a later append's output: then they go in `held`, which the page
//! appends with the settings of the append they came from.
//!
//! Audio and other tracks are converted here and wait in the job for the
//! video, so fragments come out whole and in order.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::ops::Range;

use crate::bytes::{box_extent, err, Error, Reader, Result, Writer};
use crate::frag::{self, OutSample, OutTrack, Run, Sample, NOT_SYNC, SYNC};
use crate::init::{self, Codec, Track};
use crate::progressive::{self, Cuts, FileSample, Scan};

/// How many frames back, and how many bytes, a GOP is kept for replaying.
/// Streams whose keyframes aren't IDR pictures would otherwise keep all.
const MAX_GOP: usize = 1200;
const MAX_GOP_BYTES: usize = 32 << 20;

/// Changes whenever `save_state`'s layout does.
const STATE_VERSION: u32 = 1;

fn put_opt(w: &mut Writer, v: Option<i64>) {
    w.u8(u8::from(v.is_some()));
    w.u64(v.unwrap_or(0) as u64);
}

fn get_opt(r: &mut Reader<'_>) -> Result<Option<i64>> {
    let some = r.u8()? != 0;
    let v = r.u64()? as i64;
    Ok(some.then_some(v))
}

/// The most input that may wait to be converted: a fragment, or the part of
/// a progressive file between its earliest and latest unconverted samples.
pub const MAX_INPUT: usize = 192 << 20;

/// Frames waiting for their chunks, per track. The decoder puts out every
/// frame it will in a run or two, so more than this means frames it
/// dropped.
const MAX_FRAMES: usize = 1 << 16;

/// Flags of a job sample: an IDR picture, where decoding can start.
pub const KEY: u32 = 1;
/// Decode only: the decoder restarted midway through a GOP (after a flush),
/// so the GOP so far is decoded again, and its pictures were already
/// encoded.
pub const DECODE_ONLY: u32 = 2;
/// Flush the decoder after this job, so all its frames come out now: the
/// next fragment starts at a keyframe (or, for MSE segments, every one so
/// far has), so nothing is lost by starting over.
pub const FLUSH: u32 = 4;

/// A sample for the worker to decode, laid out for reading from JS.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct JobSample {
    pub track: u32,
    pub flags: u32,
    /// Annex-B bytes, as an offset into the job's data.
    pub offset: u32,
    pub len: u32,
    /// Microseconds; frames come back from the codecs with the same value.
    pub timestamp: f64,
    pub duration: f64,
    /// `profile_idc`, constraint flags and `level_idc`, for "avc1.PPCCLL".
    pub codec: u32,
    /// The input's bits per second so far.
    pub bitrate: u32,
}

/// What `frame` says to do with a decoded frame.
pub const DROP: u32 = 0;
pub const ENCODE: u32 = 1;
/// Encode it as a keyframe: it's an IDR picture of the input.
pub const ENCODE_KEY: u32 = 2;

/// Frames of one earlier append in `held`, laid out for reading from JS.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct HeldGroup {
    /// The append (`begin`'s `seq`) whose input held these frames.
    pub seq: f64,
    /// Their presentation times in seconds, on the stream's own timeline
    /// (after the edit list, before the page's `timestampOffset`).
    pub start: f64,
    pub end: f64,
    /// Their bytes in `held`.
    pub offset: u32,
    pub len: u32,
}

#[derive(Default)]
pub struct Job {
    pub samples: Vec<JobSample>,
    pub data: Vec<u8>,
    /// Converted tracks that go out with the video.
    parts: Vec<OutTrack>,
}

/// Input bytes not converted yet. Consumed from the front with a cursor;
/// what's left moves to the front only when there's room to make.
#[derive(Default)]
pub struct Input {
    buf: Vec<u8>,
    start: usize,
    /// More than `MAX_INPUT` arrived, and some was dropped.
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

    /// Room for `n` more bytes at the end: the buffer to write them into
    /// (its spare capacity), or None past `MAX_INPUT`.
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

    /// The buffer `room` handed out, to account for what was written.
    pub fn buffer(&mut self) -> &mut Vec<u8> {
        &mut self.buf
    }
}

/// The GOP so far, to replay into a decoder that restarted midway.
#[derive(Default)]
struct Gop {
    /// Presentation time, duration and bytes in `data` of each sample.
    samples: Vec<(i64, u32, Range<usize>)>,
    data: Vec<u8>,
    /// Its start is missing, or it grew past the limits.
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
    /// Where a traf without tfdt continues.
    next_dts: i64,
    /// Where the last video fragment ended, to tell whether the next one
    /// continues it.
    end_dts: Option<i64>,
    gop: Gop,
    /// The worker's decoder restarted (or never started): the next job
    /// starts at a keyframe, or replays the GOP.
    needs_key: bool,
    /// Every fragment so far that continued the one before started with a
    /// keyframe, so the decoder may as well be flushed after each.
    aligned: bool,
    /// Counts the times decoding started over. Frames of an earlier run
    /// still in the decoder come out before any of a later one.
    run: u64,
    /// The latest presentation time of a frame handed out on this timeline.
    last_pts: Option<i64>,
    bytes: u64,
    ticks: u64,
}

/// A frame in a job whose chunk hasn't come back yet.
struct Frame {
    pts: i64,
    /// Grows to cover frames after it left out to cap the frame rate.
    duration: u32,
    /// The append whose input held the frame, and the page's number for it.
    epoch: u32,
    seq: f64,
    run: u64,
    /// An IDR picture: encoded as a keyframe.
    key: bool,
}

/// An encoded frame waiting to be written.
struct Chunk {
    pts: i64,
    duration: u32,
    epoch: u32,
    seq: f64,
    key: bool,
    size: (u16, u16),
    data: Vec<u8>,
}

/// A converted video track's frames between the job and the output.
#[derive(Default)]
struct VideoOut {
    /// Frames not decoded yet, by run and microsecond timestamp: the same
    /// timestamps come again when a page appends a fragment once more, and
    /// the decoder puts out an earlier run's frames first.
    frames: BTreeMap<(u64, i64), Frame>,
    /// Frames being encoded, in the order they went to the encoder, with
    /// their microsecond timestamps.
    encoding: VecDeque<(i64, Frame)>,
    /// Encoded frames in the order they were decoded, which is
    /// presentation order within a run.
    ready: Vec<Chunk>,
    /// The append that last wrote frames to the output (not `held`).
    main_epoch: u32,
    /// The coded size in the converted init, if the encoder's differs from
    /// the input's.
    size: Option<(u16, u16)>,
    /// The run and presentation time of the last frame sent to the encoder,
    /// which a frame left out to cap the frame rate extends.
    last_kept: Option<(u64, i64)>,
}

impl VideoOut {
    /// Whether a run's frames waiting have a gap in presentation order: a
    /// fragment that ends mid-GOP can end on a frame whose B-frames come in
    /// the next one.
    fn has_hole(&self, run: u64) -> bool {
        let mut frames: Vec<(i64, u32)> =
            self.frames.values().filter(|f| f.run == run).map(|f| (f.pts, f.duration)).collect();
        frames.sort_unstable();
        frames.windows(2).any(|w| {
            let duration = i64::from(w[0].1);
            w[1].0.saturating_sub(w[0].0.saturating_add(duration)) > duration / 2
        })
    }

    /// Makes the frame last sent to the encoder last until `f` ends, so
    /// `f` can be left out. False if there's no such frame of `f`'s run
    /// left to change: then `f` has to be encoded.
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

    /// Frames that will never come back: those of a run when frames of a
    /// later one are still waiting, past the limit.
    fn trim(&mut self) {
        if self.frames.len() > MAX_FRAMES {
            let last = self.frames.values().map(|f| f.run).max().unwrap_or(0);
            self.frames.retain(|_, f| f.run == last);
        }
    }
}

/// A progressive file's samples of one stream.
struct Table {
    samples: Vec<FileSample>,
    /// The lowest offset of each sample and all after it.
    keep: Vec<u64>,
    /// How many went out.
    done: usize,
}

struct Progressive {
    /// Absolute file offset of the input's first byte.
    base: u64,
    tables: Vec<Table>,
    cuts: Cuts,
    /// Where the fragment being gathered ends, once planned, and where the
    /// last one ended.
    cut: Option<f64>,
    last_cut: f64,
}

impl Progressive {
    /// A file that's all out, or broken: no more input is read.
    fn closed() -> Self {
        Progressive { base: 0, tables: Vec::new(), cuts: Cuts::new(None, 0.0), cut: None, last_cut: 0.0 }
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
    /// The input moov's body, to write the converted init from again when
    /// the encoder's size changes.
    moov: Vec<u8>,
    /// Whether the converted moov is a progressive file's.
    moov_progressive: bool,
    sequence: u32,
    job: Option<Job>,
    prog: Option<Progressive>,
    video: HashMap<u32, VideoOut>,
    /// Counts appends (and drains), so frames know which they came in, and
    /// the page's number for the current one.
    epoch: u32,
    seq: f64,
    /// What the worker takes after each append: the output, and frames of
    /// earlier appends to append before it, a group per append.
    pub output: Vec<u8>,
    pub held: Vec<u8>,
    pub held_groups: Vec<HeldGroup>,
    /// Converted inits written to `output` or `held` since they were taken.
    pub inits_out: u32,
    /// What a fresh converter needs to carry on from this one (`save_state`).
    pub state: Vec<u8>,
    /// Where the worker puts an encoded chunk for `chunk`.
    pub chunk_buffer: Vec<u8>,
    pub error: String,
    /// The converted init's MIME type, once there is one.
    pub mime: String,
    /// The last input init segment, kept so a fresh converter can be primed
    /// with it, and a counter that changes whenever it does.
    pub init: Vec<u8>,
    pub init_generation: u32,
    ftyp: Vec<u8>,
    /// The converted init last written, ftyp and moov, and whether the
    /// output needs it again: after `reset`, the page may have dropped the
    /// append that had it.
    out_ftyp: Vec<u8>,
    out_init: Vec<u8>,
    reinit: bool,
    /// Which of `held` and `output` got the init again in this append.
    reinit_done: [bool; 2],
}

/// What `poll` found.
#[derive(Debug, PartialEq, Eq)]
pub enum Poll {
    /// Everything complete so far is in `output`.
    Idle,
    /// A job waits for its video.
    Job,
}

impl Converter {
    pub fn new(progressive: bool) -> Self {
        Converter { progressive, ..Self::default() }
    }

    /// Starts an append (or a drain): what comes out from here on belongs to
    /// it, and frames of earlier ones go in `held`.
    pub fn begin(&mut self, seq: f64) {
        if self.reinit_done.iter().any(|&d| d) {
            self.reinit = false;
        }
        self.reinit_done = [false; 2];
        self.epoch = self.epoch.wrapping_add(1);
        self.seq = seq;
    }

    /// Whether input is still read: a progressive file that's all out has
    /// only trailing boxes left.
    pub fn wants_input(&self) -> bool {
        self.prog.as_ref().is_none_or(|p| !p.finished())
    }

    /// Takes the output, `held` and its groups, once JS has copied them.
    pub fn clear_output(&mut self) {
        for buf in [&mut self.output, &mut self.held] {
            buf.clear();
            // A big append's output needn't stay allocated.
            if buf.capacity() > 16 << 20 {
                *buf = Vec::new();
            }
        }
        self.held_groups.clear();
        self.inits_out = 0;
    }

    /// Drops the output of an append that failed: the page never gets it,
    /// so the converted init in it, if any, comes again before the next.
    pub fn discard_output(&mut self) {
        self.clear_output();
        if !self.out_init.is_empty() {
            self.reinit = true;
            self.reinit_done = [false; 2];
        }
    }

    /// The first video track's display size, as the engine would show the
    /// input: its sample entry's size, stretched by its pixel aspect ratio,
    /// or else to its track header's aspect.
    pub fn natural(&self) -> Option<(u32, u32)> {
        self.streams.iter().find(|s| s.track.is_video()).and_then(|s| s.track.natural())
    }

    pub fn push(&mut self, bytes: &[u8]) {
        if !self.wants_input() {
            return;
        }
        if let Some(buf) = self.input.room(bytes.len()) {
            buf.extend_from_slice(bytes);
        }
    }

    /// Accounts for `len` bytes written past the end of the input, or
    /// forgets them if they aren't wanted.
    pub fn committed(&mut self, len: usize) {
        if !self.wants_input() {
            let buf = self.input.buffer();
            buf.truncate(buf.len().saturating_sub(len));
        }
    }

    /// Converts what's complete, up to the next job.
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
            // A broken file stays broken; stop reading it.
            self.input.clear();
            self.prog = Some(Progressive::closed());
        }
        r
    }

    pub fn job(&self) -> Option<&Job> {
        self.job.as_ref()
    }

    /// An encoded chunk for a frame of some job, with the frame's timestamp
    /// and the coded size. Chunks of frames no job has, or that came too
    /// late to be written in order, are dropped.
    pub fn chunk(&mut self, track: u32, timestamp: f64, key: bool, size: (u16, u16), data: Vec<u8>) -> Result<()> {
        if !timestamp.is_finite() {
            return err("chunk without a timestamp");
        }
        let Some(v) = self.video.get_mut(&track) else {
            return Ok(());
        };
        // The encoder puts chunks out in the order it got the frames.
        let ts = timestamp.round() as i64;
        let Some(f) = v.encoding.iter().position(|(t, _)| *t == ts).and_then(|i| v.encoding.remove(i)).map(|(_, f)| f)
        else {
            return Ok(());
        };
        v.ready.push(Chunk { pts: f.pts, duration: f.duration, epoch: f.epoch, seq: f.seq, key, size, data });
        Ok(())
    }

    /// The decoder put out the frame with `timestamp`: whether to encode
    /// it (`ENCODE`, or `ENCODE_KEY` at an IDR picture) or `DROP` it.
    /// Frames no job has, and frames that would go back in time (the
    /// decoder puts frames out in presentation order within a run, unless
    /// the input's timestamps are wrong), are dropped, so that what the
    /// encoder gets is exactly what's written. `skip` asks to leave the
    /// frame out to cap the frame rate: then the frame before it lasts
    /// until the next, unless it's a keyframe or there's no frame before it
    /// to stretch, and then it's encoded after all.
    pub fn frame(&mut self, track: u32, timestamp: f64, skip: bool) -> u32 {
        let Some(v) = self.video.get_mut(&track) else {
            return DROP;
        };
        if !timestamp.is_finite() {
            return DROP;
        }
        let ts = timestamp.round() as i64;
        // The oldest run with a frame at this time: runs are few.
        let mut found = None;
        let mut next = v.frames.keys().next().map(|k| k.0);
        while let Some(run) = next {
            if v.frames.contains_key(&(run, ts)) {
                found = Some(run);
                break;
            }
            next = v.frames.range((run.saturating_add(1), i64::MIN)..).next().map(|(k, _)| k.0).filter(|&r| r > run);
        }
        let Some(f) = found.and_then(|run| v.frames.remove(&(run, ts))) else {
            return DROP;
        };
        // The run's earlier frames, and earlier runs, have all come out.
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

    /// The worker flushed `track`'s decoder and every chunk is in: frames
    /// that didn't come out never will, and the next job starts over.
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

    /// The worker lost its codecs (an error, or the engine reclaimed them):
    /// frames in flight are gone, and the job too.
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

    /// Ends the current job, if any, and writes its fragment with every
    /// chunk so far.
    pub fn write(&mut self) -> Result<()> {
        let parts = self.job.take().map(|j| j.parts).unwrap_or_default();
        self.write_parts(parts)
    }

    /// The page aborted: drop partial input and decoding state, keep the
    /// init, and send it again before the next output.
    pub fn reset(&mut self) {
        self.input.clear();
        self.input.overflow = false;
        self.job = None;
        self.prog = None;
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
    }

    /// Whether a fresh converter primed with `init` and given this one's
    /// `save_state` would carry on the same: nothing waits in this one
    /// (no input, no frames in the codecs), and the state that matters fits
    /// in `save_state`. An AAC decoder carries the overlap of its last
    /// frame, which can't be moved, so streams with AAC are recycled only
    /// before their first frame or right after a reset.
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

    /// Writes what a fresh converter needs to carry on from this one into
    /// `state`: where each stream is, the GOP it may replay, and the
    /// counters that order frames and fragments.
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
        }
        self.state = w.buf;
    }

    /// Takes over a converter's `save_state`, after the same init primed
    /// this one. Fails, changing nothing, if they don't match.
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
            ));
        }
        for (s, l) in self.streams.iter_mut().zip(loaded) {
            let (next_dts, end_dts, needs_key, aligned, run, last_pts, bytes, ticks, gop, main_epoch, size) = l;
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
            }
        }
        self.epoch = epoch;
        self.sequence = sequence;
        Ok(())
    }

    pub fn fail(&mut self, e: &Error) {
        self.error.clone_from(&e.0);
    }

    /// Adds to `held` or the output, with the converted init first if the
    /// page may have lost it.
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
            self.sequence = self.sequence.wrapping_add(1);
            let bytes = frag::write_fragment(self.sequence, tracks);
            self.emit(held, &bytes, false);
        }
    }

    /// Writes the converted init again from the input moov, with the coded
    /// sizes the encoder uses now.
    fn write_init(&mut self, held: bool) -> Result<()> {
        let tracks: Vec<&Track> = self.streams.iter().map(|s| &s.track).collect();
        let video = &self.video;
        let moov =
            init::write_moov(&self.moov, &tracks, self.moov_progressive, &|id| video.get(&id).and_then(|v| v.size))?;
        self.out_init.clone_from(&self.out_ftyp);
        self.out_init.extend_from_slice(&moov);
        self.emit(held, &moov, true);
        Ok(())
    }

    /// Writes every video chunk so far, and `parts` with the first fragment.
    fn write_parts(&mut self, mut parts: Vec<OutTrack>) -> Result<()> {
        let mut ids: Vec<u32> = self.video.keys().copied().collect();
        ids.sort_unstable();
        for id in ids {
            let Some(v) = self.video.get_mut(&id) else {
                continue;
            };
            let mut ready = std::mem::take(&mut v.ready);
            // Frames of earlier appends go in `held`, up to the first of
            // this one's: after that, frames have to follow it.
            let held =
                if v.main_epoch == self.epoch { 0 } else { ready.iter().take_while(|c| c.epoch != self.epoch).count() };
            if held < ready.len() {
                v.main_epoch = self.epoch;
            }
            let main = ready.split_off(held);
            // A group per earlier append, in the order they came.
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

    /// Writes chunks of one earlier append to `held`, as a group of their
    /// own with that append's number and their time range.
    fn write_held(&mut self, id: u32, chunks: Vec<Chunk>) -> Result<()> {
        let Some(first) = chunks.first() else {
            return Ok(());
        };
        let seq = first.seq;
        let (timescale, edit) =
            self.streams.iter().find(|s| s.track.id == id).map_or((1, 0), |s| (s.track.timescale, s.track.edit_offset));
        let seconds = |ticks: i64| ticks.saturating_sub(edit) as f64 / f64::from(timescale.max(1));
        let start = seconds(chunks.iter().map(|c| c.pts).min().unwrap_or(0));
        let end = seconds(chunks.iter().map(|c| c.pts.saturating_add(i64::from(c.duration))).max().unwrap_or(0));
        let at = self.held.len();
        self.write_video(id, chunks, true, &mut Vec::new())?;
        let len = self.held.len() - at;
        if len == 0 {
            return Ok(());
        }
        match self.held_groups.last_mut() {
            // The same append's frames once more, right after: one group.
            Some(g) if g.seq.to_bits() == seq.to_bits() && g.offset as usize + g.len as usize == at => {
                g.len += len as u32;
                g.start = g.start.min(start);
                g.end = g.end.max(end);
            }
            _ => self.held_groups.push(HeldGroup { seq, start, end, offset: at as u32, len: len as u32 }),
        }
        Ok(())
    }

    /// Writes one track's chunks as fragments: a new one wherever the
    /// timeline jumps, and a new init first where a keyframe has another
    /// size. The first fragment takes `parts` along.
    fn write_video(&mut self, id: u32, chunks: Vec<Chunk>, held: bool, parts: &mut Vec<OutTrack>) -> Result<()> {
        let source = self.streams.iter().find(|s| s.track.id == id).and_then(|s| s.track.size());
        let mut current = self.video.get(&id).and_then(|v| v.size).or(source);
        let mut run: Vec<(i64, OutSample)> = Vec::new();
        for c in chunks {
            // Decode times can't be negative; the engine would cut these
            // frames off the timeline anyway.
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
                // VP9 has no reordering, so each frame is decoded at its
                // presentation time and lasts until the next one, unless the
                // timeline jumps there.
                if gap > 0 && gap <= i64::from(last.duration.max(1)) * 4 {
                    last.duration = u32::try_from(gap).unwrap_or(u32::MAX);
                } else {
                    self.flush_run(id, &mut run, held, parts);
                }
            }
            let flags = if c.key { SYNC } else { NOT_SYNC };
            run.push((c.pts, OutSample { duration: c.duration.max(1), flags, cto: 0, data: c.data }));
        }
        self.flush_run(id, &mut run, held, parts);
        Ok(())
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
                    // Lost sync with the box structure; nothing after it can be read.
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
                // The moof's mdat has to be here too.
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
            let bytes = data[..size].to_vec();
            self.input.consume(size);
            match &kind {
                b"ftyp" => {
                    self.emit(false, &bytes, true);
                    self.out_ftyp.clone_from(&bytes);
                    self.ftyp = bytes;
                }
                b"moov" => self.open_init(&bytes, header)?,
                // styp, sidx, emsg, prft, free and the like mean nothing to
                // the engine, and a stray mdat has nothing pointing into it.
                _ => {}
            }
        }
    }

    fn open_init(&mut self, moov: &[u8], header: usize) -> Result<()> {
        let body = &moov[header..];
        let tracks = init::parse_moov(body)?;
        self.mime = init::mime(&tracks);
        // Players append the same init again at every discontinuity or
        // quality switch; the tracks carry on through an identical one.
        if body != self.moov || self.streams.is_empty() {
            for t in tracks.iter().filter(|t| t.is_video()) {
                self.video.entry(t.id).or_default().size = None;
            }
            self.streams = tracks.into_iter().map(Stream::new).collect();
            self.moov = body.to_vec();
        }
        self.moov_progressive = false;
        self.write_init(false)?;
        self.reinit = false;
        self.init.clone_from(&self.ftyp);
        self.init.extend_from_slice(moov);
        self.init_generation = self.init_generation.wrapping_add(1);
        Ok(())
    }

    /// Converts one moof+mdat. Returns true if it became a job.
    fn fragment(&mut self, unit: &[u8]) -> Result<bool> {
        if self.streams.is_empty() {
            return err("media segment before an init segment");
        }
        let lookup = |id: u32| self.streams.iter().find(|s| s.track.id == id).map(|s| (s.track.defaults, s.next_dts));
        let runs = frag::parse_moof(unit, &lookup)?;
        self.convert_runs(runs, unit, &[])
    }

    /// `next_key` says, for tracks where it's known, whether the fragment
    /// after this one starts with a keyframe.
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
                // A fragmented file, as X serves its fallback MP4s, reads
                // like MSE segments.
                return if self.progressive { Ok(Poll::Idle) } else { self.poll_fragmented() };
            }
            let Some(prog) = self.prog.as_mut() else {
                return Ok(Poll::Idle);
            };
            if prog.finished() {
                return Ok(Poll::Idle);
            }
            let have = prog.base + self.input.len() as u64;
            let cut = if let Some(cut) = prog.cut {
                cut
            } else {
                // From the first sample still to go out, so spans
                // without samples are skipped, not cut up.
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
            // Each stream's samples up to the cut, if all their bytes are here.
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
            let base = prog.base;
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
            // Bytes before every remaining sample aren't needed again.
            let keep_from = prog.tables.iter().filter_map(|t| t.keep.get(t.done).copied()).min();
            let input = std::mem::take(&mut self.input);
            let became_job = self.convert_runs(runs, input.data(), &next_key);
            self.input = input;
            if let Some(prog) = self.prog.as_mut() {
                let drop = keep_from.map_or(self.input.len() as u64, |k| k.saturating_sub(prog.base));
                let drop = drop.min(self.input.len() as u64);
                self.input.consume(drop as usize);
                prog.base += drop;
            }
            if became_job? {
                return Ok(Poll::Job);
            }
        }
    }

    /// Reads the moov once it has arrived. Returns whether it has, and turns
    /// the converter fragmented if the file is.
    fn open_progressive(&mut self) -> Result<bool> {
        let range = match progressive::find_moov(self.input.data())? {
            Scan::Moov(range) => range,
            Scan::NeedMore => return Ok(false),
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
        self.prog = Some(Progressive { base: 0, tables, cuts, cut: None, last_cut: 0.0 });
        Ok(true)
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

    /// Adds a video fragment's samples to the job, as Annex-B, and its
    /// frames to those waiting for chunks.
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
        // WebCodecs takes timestamps up to 2^53 microseconds (285 years).
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

        // Where decoding starts: anywhere if the decoder carries on from the
        // last fragment, else at a keyframe, or by replaying the GOP so far.
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
            // Nothing to decode these from, the same as the engine would
            // drop them.
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
        // After a flush mid-GOP (a drain), the flush put out frames whose
        // B-frames, shown before them, come only now. Encoding those would
        // send the encoder back in time, so they're only decoded.
        let floor = if replay { self.last_pts } else { None };
        let mut flags = Vec::with_capacity(samples.len());
        for (s, (key, _)) in samples.iter().zip(&converted).skip(start) {
            let key = if *key { KEY } else { 0 };
            if floor.is_some_and(|floor| s.pts() < floor) {
                flags.push(key | DECODE_ONLY);
                continue;
            }
            flags.push(key);
            let frame = Frame { pts: s.pts(), duration: s.duration, epoch, seq, run: self.run, key: key != 0 };
            out.frames.insert((self.run, micros(s.pts(), timescale)), frame);
            self.last_pts = Some(self.last_pts.map_or(s.pts(), |last| last.max(s.pts())));
        }
        // Flushing puts out every frame decoded so far, so not while one
        // waits for B-frames shown before it, still to come.
        let flush = next_key.unwrap_or(self.aligned) && !out.has_hole(self.run);
        let flush = if flush { FLUSH } else { 0 };
        for ((s, (_, range)), flags) in samples.iter().zip(&converted).skip(start).zip(flags) {
            push(job, flush | flags, s.pts(), s.duration, range.clone());
        }
        if start < samples.len() {
            self.needs_key = false;
        }
        // Keep the GOP a later fragment may need to replay.
        if !continues {
            self.gop.clear();
        }
        for (s, (key, range)) in samples.iter().zip(converted) {
            self.gop.add(s.pts(), s.duration, key, &job.data[range]);
        }
        Ok(())
    }

    /// The input's bits per second so far.
    fn bitrate(&self) -> u32 {
        let seconds = self.ticks as f64 / f64::from(self.track.timescale);
        if seconds <= 0.0 {
            return 1_000_000;
        }
        (self.bytes as f64 * 8.0 / seconds).clamp(100_000.0, 40_000_000.0) as u32
    }
}

/// Ticks to whole microseconds, rounded the same way every time so frames
/// can be matched up by their timestamps.
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
        // worker.js reads them at this stride.
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
