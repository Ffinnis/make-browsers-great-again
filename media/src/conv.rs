//! One converter per `SourceBuffer`: takes the bytes the page appends, and
//! gives back init segments and fragments the engine can play.
//!
//! Video needs the engine's codecs, so a fragment with H.264 in it becomes a
//! job: the worker decodes the job's samples with `WebCodecs`, encodes VP9,
//! hands the chunks back and calls `finish`, and the fragment is written.
//! Audio and other tracks are converted here and wait in the job for the
//! video, so fragments come out whole and in order.

use std::collections::HashMap;

use crate::bytes::{box_extent, err, Error, Result};
use crate::frag::{self, OutSample, OutTrack, Run, Sample, NOT_SYNC, SYNC};
use crate::init::{self, Codec, Track};
use crate::progressive::{self, FileSample, Scan};

/// How many frames back a GOP is kept for replaying. Streams whose
/// keyframes aren't IDR pictures would otherwise keep all of them.
const MAX_GOP: usize = 1200;

/// Flags of a job sample.
pub const KEY: u32 = 1;
/// Decode only: the sample restarts the decoder midway through a GOP, and
/// its picture belongs to an earlier fragment.
pub const DECODE_ONLY: u32 = 2;
/// On a track's first sample in a job: no frames held from an earlier job
/// belong to this one (after a seek, or a new init), so drop any.
pub const UNHELD: u32 = 4;

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
    /// Bits per second to encode at.
    pub bitrate: u32,
    /// Frames of the track from this timestamp on wait, unencoded, for the
    /// next job (infinite if none do); see `Stream::hold`.
    pub hold_from: f64,
}

pub struct Job {
    pub samples: Vec<JobSample>,
    pub data: Vec<u8>,
    parts: Vec<Part>,
}

enum Part {
    Ready(OutTrack),
    Video(VideoPart),
}

struct VideoPart {
    track_id: u32,
    /// Presentation time and duration of each frame to encode, by its
    /// microsecond timestamp.
    frames: HashMap<i64, (i64, u32)>,
    chunks: Vec<(i64, bool, Vec<u8>)>,
}

struct Stream {
    track: Track,
    next_dts: i64,
    /// Annex-B samples since the last keyframe, to restart the decoder when
    /// a fragment begins mid-GOP: (dts, pts, duration, data).
    gop: Vec<(i64, i64, u32, Vec<u8>)>,
    /// Frames the worker holds for the next job: (timestamp, pts, duration).
    held: Vec<(i64, i64, u32)>,
    bytes: u64,
    ticks: u64,
}

struct Progressive {
    /// Absolute file offset of `input[0]`.
    base: u64,
    /// Per stream: its samples in the file, and how many went out.
    tables: Vec<(Vec<FileSample>, usize)>,
    cuts: Vec<f64>,
    next_cut: usize,
}

#[derive(Default)]
pub struct Converter {
    progressive: bool,
    input: Vec<u8>,
    streams: Vec<Stream>,
    sequence: u32,
    job: Option<Job>,
    prog: Option<Progressive>,
    /// What the worker takes after each append.
    pub output: Vec<u8>,
    pub error: String,
    /// The converted init's MIME type, once there is one.
    pub mime: String,
    /// The last input init segment, kept so a fresh converter can be primed
    /// with it, and a counter that changes whenever it does.
    pub init: Vec<u8>,
    pub init_generation: u32,
    ftyp: Vec<u8>,
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

    pub fn push(&mut self, bytes: &[u8]) {
        if self.prog.as_ref().is_some_and(|p| p.next_cut >= p.cuts.len()) {
            // A progressive file that's all out; the rest is trailing boxes.
            return;
        }
        self.input.extend_from_slice(bytes);
    }

    /// Converts what's complete, up to the next job.
    pub fn poll(&mut self) -> Result<Poll> {
        if self.job.is_some() {
            return Ok(Poll::Job);
        }
        if !self.progressive {
            return self.poll_fragmented();
        }
        let r = self.poll_progressive();
        if r.is_err() {
            // A broken file stays broken; stop reading it.
            self.input.clear();
            self.prog = Some(Progressive { base: 0, tables: Vec::new(), cuts: Vec::new(), next_cut: 0 });
        }
        r
    }

    pub fn job(&self) -> Option<&Job> {
        self.job.as_ref()
    }

    /// An encoded chunk for the current job.
    pub fn chunk(&mut self, track_id: u32, timestamp: f64, key: bool, data: &[u8]) -> Result<()> {
        let Some(job) = self.job.as_mut() else {
            return err("no job");
        };
        for part in &mut job.parts {
            if let Part::Video(v) = part {
                if v.track_id == track_id {
                    v.chunks.push((timestamp.round() as i64, key, data.to_vec()));
                    return Ok(());
                }
            }
        }
        err("chunk for a track not in the job")
    }

    /// Writes the job's fragment from the chunks it got. Frames that never
    /// came back leave the previous frame showing longer.
    pub fn finish(&mut self) -> Result<()> {
        let Some(job) = self.job.take() else {
            return err("no job");
        };
        let mut tracks = Vec::new();
        for part in job.parts {
            match part {
                Part::Ready(t) => tracks.push(t),
                Part::Video(v) => tracks.push(video_track(v)),
            }
        }
        self.write(&tracks);
        Ok(())
    }

    /// The page aborted: drop partial input and decoding state, keep the
    /// init.
    pub fn reset(&mut self) {
        self.input.clear();
        self.job = None;
        self.prog = None;
        for s in &mut self.streams {
            s.gop.clear();
            s.held.clear();
            if let Codec::Aac(a) = &mut s.track.codec {
                a.reset();
            }
        }
    }

    pub fn fail(&mut self, e: &Error) {
        self.error.clone_from(&e.0);
    }

    fn write(&mut self, tracks: &[OutTrack]) {
        if tracks.iter().any(|t| !t.samples.is_empty()) {
            self.sequence += 1;
            self.output.extend_from_slice(&frag::write_fragment(self.sequence, tracks));
        }
    }

    fn poll_fragmented(&mut self) -> Result<Poll> {
        loop {
            let (size, header) = match box_extent(&self.input) {
                Ok(Some(extent)) => extent,
                Ok(None) => return Ok(Poll::Idle),
                Err(e) => {
                    // Lost sync with the box structure; nothing after it can be read.
                    self.input.clear();
                    return Err(e);
                }
            };
            if size > self.input.len() {
                return Ok(Poll::Idle);
            }
            let kind: [u8; 4] = [self.input[4], self.input[5], self.input[6], self.input[7]];
            if &kind == b"moof" {
                // The moof's mdat has to be here too.
                let rest = &self.input[size..];
                let Some((mdat_size, _)) = box_extent(rest)? else {
                    return Ok(Poll::Idle);
                };
                if rest.get(4..8) != Some(b"mdat") {
                    self.input.drain(..size);
                    return err("moof not followed by mdat");
                }
                if mdat_size > rest.len() {
                    return Ok(Poll::Idle);
                }
                let unit: Vec<u8> = self.input.drain(..size + mdat_size).collect();
                if self.fragment(&unit)? {
                    return Ok(Poll::Job);
                }
                continue;
            }
            let bytes: Vec<u8> = self.input.drain(..size).collect();
            match &kind {
                b"ftyp" => {
                    self.output.extend_from_slice(&bytes);
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
        self.output.extend_from_slice(&init::write_moov(body, &tracks, false)?);
        self.mime = init::mime(&tracks);
        self.init.clone_from(&self.ftyp);
        self.init.extend_from_slice(moov);
        self.init_generation += 1;
        self.streams = tracks.into_iter().map(Stream::new).collect();
        Ok(())
    }

    /// Converts one moof+mdat. Returns true if it became a job.
    fn fragment(&mut self, unit: &[u8]) -> Result<bool> {
        if self.streams.is_empty() {
            return err("media segment before an init segment");
        }
        let lookup = |id: u32| self.streams.iter().find(|s| s.track.id == id).map(|s| (s.track.defaults, s.next_dts));
        let runs = frag::parse_moof(unit, &lookup)?;
        self.convert_runs(runs, unit)
    }

    fn convert_runs(&mut self, runs: Vec<Run>, data: &[u8]) -> Result<bool> {
        let mut job = Job { samples: Vec::new(), data: Vec::new(), parts: Vec::new() };
        for run in runs {
            let Some(stream) = self.streams.iter_mut().find(|s| s.track.id == run.track_id) else {
                continue;
            };
            if let Some(last) = run.samples.last() {
                stream.next_dts = last.dts + i64::from(last.duration);
            }
            let part = stream.convert(&run.samples, data, &mut job)?;
            job.parts.push(part);
        }
        if job.parts.iter().any(|p| matches!(p, Part::Video(_))) {
            self.job = Some(job);
            return Ok(true);
        }
        let tracks: Vec<OutTrack> = job
            .parts
            .into_iter()
            .filter_map(|p| match p {
                Part::Ready(t) => Some(t),
                Part::Video(_) => None,
            })
            .collect();
        self.write(&tracks);
        Ok(false)
    }

    fn poll_progressive(&mut self) -> Result<Poll> {
        if self.prog.is_none() && !self.open_progressive()? {
            // A fragmented file, as X serves its fallback MP4s, reads
            // like MSE segments.
            return if self.progressive { Ok(Poll::Idle) } else { self.poll_fragmented() };
        }
        let Some(prog) = self.prog.as_mut() else {
            return Ok(Poll::Idle);
        };
        let have = prog.base + self.input.len() as u64;
        let Some(&cut) = prog.cuts.get(prog.next_cut) else {
            return Ok(Poll::Idle);
        };
        // Each stream's samples up to the cut, if all their bytes are here.
        let mut picks = Vec::new();
        for (stream, (table, done)) in self.streams.iter().zip(&prog.tables) {
            let timescale = f64::from(stream.track.timescale);
            let n = table[*done..].iter().take_while(|s| (s.dts as f64 / timescale) < cut).count();
            let picked = &table[*done..*done + n];
            if picked.iter().any(|s| s.offset + u64::from(s.size) > have) {
                return Ok(Poll::Idle);
            }
            picks.push(n);
        }
        let base = prog.base;
        let mut runs = Vec::new();
        for ((stream, (table, done)), n) in self.streams.iter().zip(&mut prog.tables).zip(picks) {
            let samples: Vec<Sample> = table[*done..*done + n].iter().map(|s| s.at(base)).collect();
            *done += n;
            runs.push(Run { track_id: stream.track.id, samples });
        }
        prog.next_cut += 1;
        // Bytes before every remaining sample aren't needed again.
        let keep_from = prog.tables.iter().filter_map(|(t, done)| t[*done..].iter().map(|s| s.offset).min()).min();
        let input = std::mem::take(&mut self.input);
        let became_job = self.convert_runs(runs, &input);
        self.input = input;
        if let Some(prog) = self.prog.as_mut() {
            let drop = keep_from.map_or(self.input.len() as u64, |k| k.saturating_sub(prog.base));
            let drop = drop.min(self.input.len() as u64);
            self.input.drain(..drop as usize);
            prog.base += drop;
        }
        if became_job? {
            Ok(Poll::Job)
        } else {
            self.poll_progressive()
        }
    }

    /// Reads the moov once it has arrived. Returns whether it has, and turns
    /// the converter fragmented if the file is.
    fn open_progressive(&mut self) -> Result<bool> {
        let range = match progressive::find_moov(&self.input)? {
            Scan::Moov(range) => range,
            Scan::NeedMore => return Ok(false),
        };
        let moov = self.input[range].to_vec();
        if crate::bytes::child(&moov, *b"mvex")?.is_some() {
            self.progressive = false;
            return Ok(false);
        }
        let mut tracks = Vec::new();
        let mut tables = Vec::new();
        for (track, trak) in init::parse_moov(&moov)?.into_iter().zip(progressive::traks(&moov)?) {
            // Only what the engine will be told about: H.264 and AAC.
            if matches!(track.codec, Codec::Other) {
                continue;
            }
            tables.push((progressive::samples(trak)?, 0));
            tracks.push(track);
        }
        if tracks.is_empty() {
            return err("no H.264 or AAC track");
        }
        let end = tracks
            .iter()
            .zip(&tables)
            .map(|(t, (s, _))| {
                s.last().map_or(0.0, |s| (s.dts + i64::from(s.duration)) as f64 / f64::from(t.timescale))
            })
            .fold(0.0, f64::max);
        let video = tracks.iter().zip(&tables).find(|(t, _)| t.is_video()).map(|(t, (s, _))| (&s[..], t.timescale));
        let cuts = progressive::cut_times(video, end);
        let mut ftyp = crate::bytes::Writer::new();
        ftyp.begin(*b"ftyp");
        ftyp.bytes(b"iso6");
        ftyp.u32(0);
        ftyp.bytes(b"iso6mp41");
        ftyp.end();
        self.output.extend_from_slice(&ftyp.buf);
        self.output.extend_from_slice(&init::write_moov(&moov, &tracks, true)?);
        self.mime = init::mime(&tracks);
        self.streams = tracks.into_iter().map(Stream::new).collect();
        self.prog = Some(Progressive { base: 0, tables, cuts, next_cut: 0 });
        Ok(true)
    }
}

impl Stream {
    fn new(track: Track) -> Self {
        Stream { track, next_dts: 0, gop: Vec::new(), held: Vec::new(), bytes: 0, ticks: 0 }
    }

    fn convert(&mut self, samples: &[Sample], data: &[u8], job: &mut Job) -> Result<Part> {
        let id = self.track.id;
        let base_dts = samples.first().map_or(0, |s| s.dts.max(0) as u64);
        let mut out = Vec::with_capacity(samples.len());
        match &mut self.track.codec {
            Codec::Avc(_) => return self.video(samples, data, job),
            Codec::Aac(conv) => {
                for s in samples {
                    let flac = conv.convert(&data[s.data.clone()], s.dts);
                    out.push(OutSample { duration: s.duration, flags: SYNC, cto: 0, data: flac });
                }
            }
            Codec::Other => {
                for s in samples {
                    let cto = i32::try_from(s.cto).map_or_else(|_| err("composition offset out of range"), Ok)?;
                    out.push(OutSample {
                        duration: s.duration,
                        flags: s.flags,
                        cto,
                        data: data[s.data.clone()].to_vec(),
                    });
                }
            }
        }
        Ok(Part::Ready(OutTrack { id, base_dts, samples: out }))
    }

    fn video(&mut self, samples: &[Sample], data: &[u8], job: &mut Job) -> Result<Part> {
        let Codec::Avc(avc) = &self.track.codec else {
            return err("not video");
        };
        let mut converted = Vec::with_capacity(samples.len());
        for s in samples {
            let mut annex_b = Vec::with_capacity(s.data.len() + 64);
            let key = avc.to_annex_b(&data[s.data.clone()], &mut annex_b)?;
            converted.push((s, key, annex_b));
            self.bytes += s.data.len() as u64;
            self.ticks += u64::from(s.duration);
        }
        let codec = avc.codec_word();
        let timescale = self.track.timescale;
        let bitrate = self.bitrate();
        let push = |job: &mut Job, flags: u32, pts: i64, duration: u32, bytes: &[u8]| {
            job.samples.push(JobSample {
                track: self.track.id,
                flags,
                offset: job.data.len() as u32,
                len: bytes.len() as u32,
                timestamp: micros(pts, timescale) as f64,
                duration: micros(i64::from(duration), timescale) as f64,
                codec,
                bitrate,
                hold_from: f64::INFINITY,
            });
            job.data.extend_from_slice(bytes);
        };
        let first_sample = job.samples.len();

        let starts_with_key = converted.first().is_some_and(|c| c.1);
        let continues = self.gop.last().is_some_and(|g| samples.first().is_some_and(|s| g.0 + i64::from(g.2) == s.dts));
        let mut skip = 0;
        if !starts_with_key {
            if continues {
                // The decoder was flushed after the last fragment and needs a
                // keyframe again: replay the GOP so far without encoding it.
                for (i, (_, pts, duration, bytes)) in self.gop.iter().enumerate() {
                    push(job, if i == 0 { KEY | DECODE_ONLY } else { DECODE_ONLY }, *pts, *duration, bytes);
                }
            } else {
                // Nothing to decode these from, the same as the engine would
                // drop them.
                skip = converted.iter().position(|c| c.1).unwrap_or(converted.len());
            }
        }
        let mut frames = std::mem::take(&mut self.held);
        if frames.is_empty() {
            if let Some(first) = job.samples.get_mut(first_sample) {
                first.flags |= UNHELD;
            }
        }
        for (s, key, bytes) in &converted[skip..] {
            push(job, if *key { KEY } else { 0 }, s.pts(), s.duration, bytes);
            frames.push((micros(s.pts(), timescale), s.pts(), s.duration));
        }
        self.held = hold(&mut frames);
        if let Some(&(from, _, _)) = self.held.first() {
            for s in &mut job.samples[first_sample..] {
                s.hold_from = from as f64;
            }
        }
        let frames = frames.into_iter().map(|(ts, pts, duration)| (ts, (pts, duration))).collect();
        // Keep the GOP the next fragment may continue. It always starts
        // with a keyframe, or is empty.
        if !continues {
            self.gop.clear();
        }
        for (s, key, bytes) in converted {
            if key {
                self.gop.clear();
            }
            if key || !self.gop.is_empty() {
                self.gop.push((s.dts, s.pts(), s.duration, bytes));
            }
        }
        if self.gop.len() > MAX_GOP {
            self.gop.clear();
        }
        Ok(Part::Video(VideoPart { track_id: self.track.id, frames, chunks: Vec::new() }))
    }

    /// Twice the source's rate: bits are free when nothing leaves the machine.
    fn bitrate(&self) -> u32 {
        let seconds = self.ticks as f64 / f64::from(self.track.timescale);
        if seconds <= 0.0 {
            return 2_000_000;
        }
        (2.0 * self.bytes as f64 * 8.0 / seconds).clamp(200_000.0, 40_000_000.0) as u32
    }
}

/// Splits off the frames after the first hole in presentation order. A
/// fragment that ends mid-GOP can end on a frame whose B-frames come in the
/// next fragment; VP9 has no reordering, so that frame has to wait and be
/// encoded after them. `frames` is left sorted, with what can go now.
fn hold(frames: &mut Vec<(i64, i64, u32)>) -> Vec<(i64, i64, u32)> {
    frames.sort_by_key(|f| f.1);
    let hole = frames.windows(2).position(|w| {
        let duration = i64::from(w[0].2);
        w[1].1 - (w[0].1 + duration) > duration / 2
    });
    match hole {
        Some(i) => frames.split_off(i + 1),
        None => Vec::new(),
    }
}

/// The converted video track: VP9 has no reordering, so each frame is
/// decoded at its presentation time, and lasts until the next one; the last
/// lasts as long as in the input.
fn video_track(v: VideoPart) -> OutTrack {
    let mut frames: Vec<(i64, u32, bool, Vec<u8>)> = v
        .chunks
        .into_iter()
        .filter_map(|(ts, key, data)| v.frames.get(&ts).map(|&(pts, duration)| (pts, duration, key, data)))
        .filter(|f| f.0 >= 0)
        .collect();
    frames.sort_by_key(|f| f.0);
    frames.dedup_by_key(|f| f.0);
    let base_dts = frames.first().map_or(0, |f| f.0 as u64);
    let mut samples = Vec::with_capacity(frames.len());
    for i in 0..frames.len() {
        let (pts, own) = (frames[i].0, frames[i].1);
        let next = frames.get(i + 1).map_or(pts + i64::from(own), |f| f.0);
        let (_, _, key, data) = std::mem::take(&mut frames[i]);
        let duration = u32::try_from((next - pts).max(1)).unwrap_or(u32::MAX);
        samples.push(OutSample { duration, flags: if key { SYNC } else { NOT_SYNC }, cto: 0, data });
    }
    OutTrack { id: v.track_id, base_dts, samples }
}

/// Ticks to whole microseconds, rounded the same way every time so frames
/// can be matched up by their timestamps.
fn micros(ticks: i64, timescale: u32) -> i64 {
    let ts = i128::from(timescale.max(1));
    let us = (i128::from(ticks) * 1_000_000 + ts / 2).div_euclid(ts);
    us as i64
}
