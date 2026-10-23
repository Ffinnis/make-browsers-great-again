//! Runs the fixtures through the converter, standing in for the worker:
//! a fake decoder that holds frames back the way H.264 decoders do, and
//! fake "VP9" chunks named after their timestamps, so the fragments' timing
//! can be checked here without `WebCodecs`. Where ffmpeg is installed, its
//! demuxer and FLAC decoder check the output independently.

// Helpers here are test code too.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use mbga_media::{Converter, HeldGroup, Natural, Poll, DECODE_ONLY, DROP, ENCODE_KEY, FINISH, FLUSH, KEY};

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)).unwrap()
}

/// What worker.js keeps per video track.
#[derive(Default)]
struct Decoder {
    /// Decoded frames the decoder hasn't put out yet, in presentation
    /// order, with the order they went in to keep equal timestamps apart.
    waiting: BTreeSet<(i64, u64)>,
    fed: u64,
    /// Whether decoding started.
    started: bool,
    encoder_started: bool,
    /// With a frame-rate cap, when the next frame may go to the encoder.
    next_kept: i64,
}

/// The worker: decoders that put frames out in presentation order once
/// more than `reorder` wait, or at a keyframe or a flush; an encoder that
/// takes them in that order and makes a keyframe where the input has one.
struct Worker {
    reorder: usize,
    decoders: BTreeMap<u32, Decoder>,
    decode_only: usize,
    jobs: usize,
    /// Chunks encoded.
    encoded: usize,
    /// The coded size of each chunk, and from which timestamp on to use
    /// another (as when the page's video gets smaller).
    size: (u16, u16),
    resize: Option<(i64, (u16, u16))>,
    /// The decoded pictures' visible size, and from which keyframe on it's
    /// another (as when an avc3 stream's SPS changes it).
    visible: (u16, u16),
    revisible: Option<(i64, (u16, u16))>,
    /// A frame-rate cap: the least time between frames, in microseconds.
    cap: Option<i64>,
    /// The page's number for appends and drains.
    seq: f64,
}

impl Worker {
    fn new() -> Self {
        Worker {
            reorder: 4,
            decoders: BTreeMap::new(),
            decode_only: 0,
            jobs: 0,
            encoded: 0,
            size: (320, 180),
            resize: None,
            visible: (320, 180),
            revisible: None,
            cap: None,
            seq: 0.0,
        }
    }

    fn put_out(&mut self, c: &mut Converter, track: u32, frame: (i64, u64)) {
        let d = self.decoders.get_mut(&track).unwrap();
        d.waiting.remove(&frame);
        let ts = frame.0;
        let skip = self.cap.is_some() && ts < d.next_kept;
        if let Some((from, size)) = self.revisible.filter(|&(from, _)| ts >= from) {
            let _ = from;
            self.visible = size;
            self.revisible = None;
        }
        let r = c.frame(track, ts as f64, skip, self.visible);
        if r == DROP {
            return;
        }
        if let Some(cap) = self.cap {
            d.next_kept = ts + cap - 1000;
        }
        let key = r == ENCODE_KEY || !d.encoder_started;
        // Sizes change at keyframes only.
        if let Some((from, size)) = self.resize.filter(|&(from, _)| ts >= from && key) {
            let _ = from;
            self.size = size;
            self.resize = None;
        }
        d.encoder_started = true;
        self.encoded += 1;
        c.chunk(track, ts as f64, key, self.size, format!("vp9 {ts}").into_bytes()).unwrap();
    }

    fn decode(&mut self, c: &mut Converter, track: u32, ts: i64, flags: u32) {
        let d = self.decoders.entry(track).or_default();
        assert!(d.started || flags & KEY != 0, "decoding starts without a keyframe");
        d.started = true;
        if flags & KEY != 0 {
            // An IDR picture: everything before it comes out first.
            let before: Vec<(i64, u64)> = d.waiting.iter().copied().collect();
            for frame in before {
                self.put_out(c, track, frame);
            }
        }
        let d = self.decoders.get_mut(&track).unwrap();
        d.fed += 1;
        d.waiting.insert((ts, d.fed));
        if flags & DECODE_ONLY != 0 {
            self.decode_only += 1;
        }
        while self.decoders[&track].waiting.len() > self.reorder {
            let first = *self.decoders[&track].waiting.first().unwrap();
            self.put_out(c, track, first);
        }
    }

    fn flush(&mut self, c: &mut Converter, track: u32) {
        let waiting: Vec<(i64, u64)> =
            self.decoders.get(&track).map(|d| d.waiting.iter().copied().collect()).unwrap_or_default();
        for frame in waiting {
            self.put_out(c, track, frame);
        }
        if let Some(d) = self.decoders.get_mut(&track) {
            d.started = false;
        }
        c.flushed(track);
    }

    /// Decodes a job's samples, flushing where it says to.
    fn run_job(&mut self, c: &mut Converter) {
        self.jobs += 1;
        let job = c.job().unwrap();
        let samples = job.samples.clone();
        let mut flush = BTreeSet::new();
        for s in &samples {
            if s.flags & FINISH != 0 {
                assert_eq!(s.len, 0);
                flush.insert(s.track);
                continue;
            }
            let data = &job.data[s.offset as usize..(s.offset + s.len) as usize];
            assert_eq!(&data[..4], &[0, 0, 0, 1], "not Annex-B");
            assert!(s.codec >> 16 == 0x64 || s.codec >> 16 == 0x4d, "codec {:x}", s.codec);
            assert!(s.bitrate > 0);
            if s.flags & FLUSH != 0 {
                flush.insert(s.track);
            }
        }
        for s in samples.iter().filter(|s| s.flags & FINISH == 0) {
            self.decode(c, s.track, s.timestamp as i64, s.flags);
        }
        for track in flush {
            self.flush(c, track);
        }
        c.write().unwrap();
    }

    /// One append: the bytes it gives back, `held` first.
    fn append(&mut self, c: &mut Converter, bytes: &[u8]) -> Output {
        self.seq += 1.0;
        c.begin(self.seq);
        c.push(bytes);
        loop {
            match c.poll() {
                Ok(Poll::Idle) => break,
                Ok(Poll::Job) => self.run_job(c),
                Err(e) => panic!("{e}"),
            }
        }
        c.write().unwrap();
        take(c)
    }

    /// An append of a progressive file's bytes from `offset`: None if the
    /// converter drops it, as one sent before the shim heard of `need`.
    fn append_at(&mut self, c: &mut Converter, bytes: &[u8], offset: u64) -> Option<Output> {
        if !c.offset(offset) {
            self.seq += 1.0;
            c.begin(self.seq);
            c.write().unwrap();
            let o = take(c);
            assert!(o.bytes.is_empty() && o.held.is_empty());
            return None;
        }
        Some(self.append(c, bytes))
    }

    /// Before `endOfStream()`: everything the decoders still hold.
    fn drain(&mut self, c: &mut Converter) -> Output {
        self.seq += 1.0;
        c.begin(self.seq);
        let tracks: Vec<u32> = self.decoders.keys().copied().collect();
        for track in tracks {
            self.flush(c, track);
        }
        c.write().unwrap();
        take(c)
    }
}

struct Output {
    held: Vec<u8>,
    groups: Vec<HeldGroup>,
    bytes: Vec<u8>,
    inits: u32,
    natural: Option<Natural>,
    range: Option<(f64, f64)>,
    need: Option<u64>,
}

fn take(c: &mut Converter) -> Output {
    let o = Output {
        held: c.held.clone(),
        groups: c.held_groups.clone(),
        bytes: c.output.clone(),
        inits: c.inits_out,
        natural: c.natural_out,
        range: c.output_range,
        need: c.need,
    };
    // The groups tile `held`.
    let mut at = 0;
    for g in &o.groups {
        assert_eq!(g.offset as usize, at);
        at += g.len as usize;
    }
    assert_eq!(at, o.held.len());
    c.clear_output();
    o
}

/// Feeds `input` in `step`-byte appends and drains at the end, the way the
/// shim does. Returns everything in append order.
fn convert(c: &mut Converter, w: &mut Worker, input: &[u8], step: usize) -> Vec<u8> {
    let mut out = Vec::new();
    for piece in input.chunks(step) {
        let o = w.append(c, piece);
        out.extend(o.held);
        out.extend(o.bytes);
    }
    let o = w.drain(c);
    out.extend(o.held);
    out.extend(o.bytes);
    out
}

/// The init, then each moof and its mdat, as low-latency players append.
fn units(input: &[u8]) -> Vec<Vec<u8>> {
    let mut units: Vec<Vec<u8>> = Vec::new();
    let mut pos = 0;
    while pos < input.len() {
        let size = u32::from_be_bytes(input[pos..pos + 4].try_into().unwrap()) as usize;
        if units.is_empty() || &input[pos + 4..pos + 8] == b"moof" {
            units.push(Vec::new());
        }
        units.last_mut().unwrap().extend_from_slice(&input[pos..pos + size]);
        pos += size;
    }
    units
}

fn has_ffmpeg() -> bool {
    Command::new("ffprobe").arg("-version").output().is_ok_and(|o| o.status.success())
}

fn write_temp(name: &str, data: &[u8]) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR"));
    let path = dir.join(name);
    std::fs::write(&path, data).unwrap();
    path
}

/// Each stream's packet presentation times, as ffprobe reads them.
fn packet_times(path: &Path) -> Vec<(String, BTreeSet<String>)> {
    let out = Command::new("ffprobe")
        .args(["-v", "error", "-show_entries", "packet=stream_index,pts", "-of", "csv=p=0"])
        .arg(path)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let mut streams: Vec<(String, BTreeSet<String>)> = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let mut fields = line.split(',');
        let (index, pts) = (fields.next().unwrap(), fields.next().unwrap());
        match streams.iter_mut().find(|s| s.0 == index) {
            Some(s) => {
                s.1.insert(pts.to_string());
            }
            None => streams.push((index.to_string(), BTreeSet::from([pts.to_string()]))),
        }
    }
    streams
}

fn relative(streams: Vec<(String, BTreeSet<String>)>) -> Vec<BTreeSet<i64>> {
    streams
        .into_iter()
        .map(|(_, times)| {
            let times: BTreeSet<i64> = times.iter().map(|t| t.parse().unwrap()).collect();
            let first = times.first().copied().unwrap_or_default();
            times.into_iter().map(|t| t - first).collect()
        })
        .collect()
}

fn codecs(path: &Path) -> String {
    let out = Command::new("ffprobe")
        .args(["-v", "error", "-show_entries", "stream=codec_name,sample_rate,channels", "-of", "csv=p=0"])
        .arg(path)
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).trim().replace('\n', " ")
}

/// Video decode times never go back, and nothing's marked discardable.
fn assert_decode_order(path: &Path) {
    let out = Command::new("ffprobe")
        .args(["-v", "error", "-select_streams", "v", "-show_entries", "packet=dts,flags", "-of", "csv=p=0"])
        .arg(path)
        .output()
        .unwrap();
    let mut last = i64::MIN;
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let (dts, flags) = line.split_once(',').unwrap();
        let dts: i64 = dts.parse().unwrap();
        assert!(dts > last && !flags.contains('D'), "{line} after {last}");
        last = dts;
    }
}

/// Decodes the first audio stream to 16-bit PCM with ffmpeg.
fn pcm(path: &Path, rate: Option<u32>) -> Vec<i16> {
    let mut cmd = Command::new("ffmpeg");
    cmd.args(["-v", "error", "-i"]).arg(path).args(["-map", "0:a:0", "-f", "s16le"]);
    if let Some(rate) = rate {
        cmd.args(["-ar", &rate.to_string()]);
    }
    let out = cmd.arg("-").output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    out.stdout.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect()
}

fn count(data: &[u8], kind: [u8; 4]) -> usize {
    data.windows(4).filter(|w| *w == kind).count()
}

/// The fake chunks' timestamps in some output, in order.
fn chunk_times(data: &[u8]) -> Vec<i64> {
    let text = String::from_utf8_lossy(data);
    text.match_indices("vp9 ")
        .map(|(at, _)| text[at + 4..].chars().take_while(char::is_ascii_digit).collect::<String>().parse().unwrap())
        .collect()
}

#[test]
fn muxed_cmaf_keeps_every_frame_and_its_time() {
    let input = fixture("muxed.mp4");
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    // Odd-sized appends split boxes everywhere.
    let out = convert(&mut c, &mut w, &input, 997);
    assert_eq!(w.decode_only, 0);
    assert_eq!(c.mime, "video/mp4; codecs=\"vp09.00.41.08,flac\"");
    if !has_ffmpeg() {
        return;
    }
    let src = write_temp("muxed-in.mp4", &input);
    let dst = write_temp("muxed-out.mp4", &out);
    assert_eq!(codecs(&dst), "vp9 flac,44100,2");
    assert_eq!(packet_times(&src), packet_times(&dst));
}

#[test]
fn fragments_that_start_mid_gop_carry_on_decoding() {
    let input = fixture("midgop.mp4");
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    let out = convert(&mut c, &mut w, &input, input.len());
    // The decoder carries on from one fragment to the next.
    assert_eq!(w.decode_only, 0);
    if has_ffmpeg() {
        let src = write_temp("midgop-in.mp4", &input);
        let dst = write_temp("midgop-out.mp4", &out);
        assert_eq!(packet_times(&src), packet_times(&dst));
        // Frames whose B-frames came in the next fragment waited for them,
        // so decode order never goes back.
        assert_decode_order(&dst);
    }
}

#[test]
fn frames_held_by_the_decoder_come_out_with_the_next_append() {
    let input = fixture("midgop.mp4");
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    // A moof+mdat at a time, as low-latency players append.
    let units = units(&input);
    let mut out = Vec::new();
    let mut helds = 0;
    for unit in &units {
        let o = w.append(&mut c, unit);
        let (held, own) = (chunk_times(&o.held), chunk_times(&o.bytes));
        if !held.is_empty() {
            helds += 1;
            // What belongs to an earlier append comes before this one's.
            assert!(held.iter().max() < own.iter().min().or(Some(&i64::MAX)), "{held:?} then {own:?}");
            // Grouped by the append they came in, with their time range.
            for g in &o.groups {
                assert!(g.seq < w.seq, "group of append {} in append {}", g.seq, w.seq);
                let times = chunk_times(&o.held[g.offset as usize..(g.offset + g.len) as usize]);
                let span = (g.end - g.start) * 30.0;
                assert!((span - times.len() as f64).abs() < 0.01, "{} frames over {span}", times.len());
            }
        }
        out.extend(o.held);
        out.extend(o.bytes);
    }
    assert!(helds > 0, "the decoder never held a frame over");
    let o = w.drain(&mut c);
    assert!(o.bytes.is_empty());
    assert!(!o.held.is_empty(), "the last frames come out with the drain");
    out.extend(o.held);
    if has_ffmpeg() {
        let src = write_temp("held-in.mp4", &input);
        let dst = write_temp("held-out.mp4", &out);
        assert_eq!(packet_times(&src), packet_times(&dst));
        assert_decode_order(&dst);
    }
}

#[test]
fn after_a_drain_a_fragment_mid_gop_replays_its_gop() {
    let input = fixture("midgop.mp4");
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    // The page ends the stream after the first moof, which ends mid-GOP,
    // and later carries on.
    let second = input.windows(4).enumerate().filter(|(_, w)| w == b"moof").nth(1).unwrap().0 - 4;
    let mut out = Vec::new();
    for part in [&input[..second], &[], &input[second..]] {
        let o = if part.is_empty() { w.drain(&mut c) } else { w.append(&mut c, part) };
        out.extend(o.held);
        out.extend(o.bytes);
    }
    let o = w.drain(&mut c);
    out.extend(o.held);
    assert!(w.decode_only > 0 && w.decode_only < 30, "{} decode-only samples", w.decode_only);
    if has_ffmpeg() {
        let src = write_temp("replay-in.mp4", &input);
        let dst = write_temp("replay-out.mp4", &out);
        // The drain put out the frame after the B-frames the next fragment
        // brings, so those are left out rather than shown out of order.
        let (want, got) = (&packet_times(&src)[0].1, &packet_times(&dst)[0].1);
        assert!(got.is_subset(want) && got.len() + 3 >= want.len(), "{} of {} frames", got.len(), want.len());
        assert_decode_order(&dst);
    }
}

#[test]
fn separate_video_segments() {
    let mut input = fixture("video-init.mp4");
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    let o = w.append(&mut c, &input);
    assert!(!o.bytes.is_empty(), "the init converts before any media");
    let mut out = o.bytes;
    for i in 0..3 {
        let seg = fixture(&format!("video-{i}.m4s"));
        let o = w.append(&mut c, &seg);
        // Segments start with keyframes, so each comes out whole.
        assert!(o.held.is_empty() && !o.bytes.is_empty());
        out.extend(o.bytes);
        input.extend_from_slice(&seg);
    }
    let o = w.drain(&mut c);
    assert!(o.held.is_empty() && o.bytes.is_empty(), "nothing left to drain");
    assert_eq!(w.decode_only, 0);
    if has_ffmpeg() {
        let src = write_temp("video-in.mp4", &input);
        let dst = write_temp("video-out.mp4", &out);
        assert_eq!(packet_times(&src), packet_times(&dst));
    }
}

fn audio(name: &str) -> (Vec<u8>, Vec<u8>, Converter) {
    let mut input = fixture(&format!("{name}-init.mp4"));
    for i in 0..4 {
        input.extend(fixture(&format!("{name}-{i}.m4s")));
    }
    let mut c = Converter::new(false);
    let out = convert(&mut c, &mut Worker::new(), &input, 1000);
    (input, out, c)
}

#[test]
fn aac_becomes_identical_flac() {
    let (input, out, c) = audio("aac");
    assert_eq!(c.mime, "audio/mp4; codecs=\"flac\"");
    if !has_ffmpeg() {
        return;
    }
    let src = write_temp("aac-in.mp4", &input);
    let dst = write_temp("aac-out.mp4", &out);
    assert_eq!(codecs(&dst), "flac,44100,2");
    assert_eq!(packet_times(&src), packet_times(&dst));
    let (a, b) = (pcm(&src, None), pcm(&dst, None));
    assert_eq!(a.len(), b.len());
    // Two AAC decoders round differently, but by a hair.
    let worst = a.iter().zip(&b).map(|(x, y)| (i32::from(*x) - i32::from(*y)).abs()).max().unwrap();
    assert!(worst <= 8, "samples differ by up to {worst}");
}

#[test]
fn he_aac_plays_its_core_at_half_rate() {
    let (input, out, _) = audio("heaac");
    if !has_ffmpeg() {
        return;
    }
    let src = write_temp("heaac-in.mp4", &input);
    let dst = write_temp("heaac-out.mp4", &out);
    assert_eq!(codecs(&dst), "flac,22050,2");
    assert_eq!(packet_times(&src), packet_times(&dst));
    // Same length in time as the full-rate decode, and a 440 Hz tone isn't
    // lost below the SBR band.
    let full = pcm(&src, Some(22050));
    let core = pcm(&dst, None);
    assert!(full.len().abs_diff(core.len()) <= 2 * 2048, "{} vs {}", full.len(), core.len());
    let energy = |s: &[i16]| s.iter().map(|&x| f64::from(x).powi(2)).sum::<f64>() / s.len() as f64;
    let ratio = energy(&core) / energy(&full);
    assert!((0.5..2.0).contains(&ratio), "energy ratio {ratio}");
}

#[test]
fn progressive_file_with_moov_last() {
    let input = fixture("gif.mp4");
    let mut c = Converter::new(true);
    let out = convert(&mut c, &mut Worker::new(), &input, 4096);
    assert_eq!(c.mime, "video/mp4; codecs=\"vp09.00.41.08\"");
    if has_ffmpeg() {
        let src = write_temp("gif-in.mp4", &input);
        let dst = write_temp("gif-out.mp4", &out);
        assert_eq!(packet_times(&src), packet_times(&dst));
    }
}

#[test]
fn progressive_file_with_audio_in_one_append() {
    let input = fixture("progressive.mp4");
    let mut c = Converter::new(true);
    let out = convert(&mut c, &mut Worker::new(), &input, input.len());
    assert_eq!(c.mime, "video/mp4; codecs=\"vp09.00.41.08,flac\"");
    if has_ffmpeg() {
        let src = write_temp("progressive-in.mp4", &input);
        let dst = write_temp("progressive-out.mp4", &out);
        assert_eq!(packet_times(&src), packet_times(&dst));
        // ffmpeg drops the AAC priming the edit list covers through decoder
        // side data, which FLAC doesn't get. The engine trims by timestamp,
        // the same for both.
        let (a, b) = (pcm(&src, None), pcm(&dst, None));
        assert!(b.len() >= a.len() && b.len() - a.len() <= 2 * 1024, "{} vs {}", a.len(), b.len());
    }
}

#[test]
fn progressive_file_with_sparse_keyframes_streams_in_short_fragments() {
    let input = fixture("sparse.mp4");
    let mut c = Converter::new(true);
    let mut w = Worker::new();
    let out = convert(&mut c, &mut w, &input, 16384);
    // One keyframe in six seconds, and still fragments of about two, with
    // the decoder carrying on across them: nothing decoded twice.
    assert_eq!(w.jobs, 3);
    assert_eq!(w.decode_only, 0);
    if has_ffmpeg() {
        let src = write_temp("sparse-in.mp4", &input);
        let dst = write_temp("sparse-out.mp4", &out);
        assert_eq!(packet_times(&src), packet_times(&dst));
        assert_decode_order(&dst);
    }
}

#[test]
fn reset_drops_partial_input_but_keeps_the_init() {
    let init = fixture("video-init.mp4");
    let seg = fixture("video-1.m4s");
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    w.append(&mut c, &init);
    let o = w.append(&mut c, &seg[..seg.len() / 2]);
    assert!(o.bytes.is_empty());
    c.reset();
    let o = w.append(&mut c, &seg);
    assert!(!o.bytes.is_empty());
    assert_eq!(c.init_generation, 1);
}

#[test]
fn an_init_lost_to_abort_comes_again() {
    let mut first = fixture("video-init.mp4");
    first.extend(fixture("video-0.m4s"));
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    // The page aborts this append, so the shim drops its output, init and all.
    let o = w.append(&mut c, &first);
    assert_eq!(count(&o.bytes, *b"moov"), 1);
    c.reset();
    let o = w.append(&mut c, &fixture("video-1.m4s"));
    assert_eq!(count(&o.bytes, *b"moov"), 1, "no init again");
    let at = |kind: &[u8]| o.bytes.windows(4).position(|w| w == kind).unwrap();
    assert!(at(b"ftyp") < at(b"moov") && at(b"moov") < at(b"moof"));
    // Only once.
    let o = w.append(&mut c, &fixture("video-2.m4s"));
    assert_eq!(count(&o.bytes, *b"moov"), 0);
}

#[test]
fn smaller_frames_get_their_own_init() {
    let input = fixture("midgop.mp4");
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    // Half size from the second keyframe on (at 1 s).
    w.resize = Some((1_000_000, (160, 90)));
    let out = convert(&mut c, &mut w, &input, input.len());
    assert_eq!(count(&out, *b"moov"), 2);
    let second = out.windows(4).rposition(|w| w == b"vp09").unwrap();
    // The entry's width and height, 24 bytes into it.
    assert_eq!(&out[second + 4 + 24..second + 4 + 28], &[0, 160, 0, 90]);
    // The init comes right before the fragment that starts at the keyframe.
    let after = &out[second..];
    let first_chunk = chunk_times(after)[0];
    assert!((1_000_000..1_100_000).contains(&first_chunk), "{first_chunk}");
    if has_ffmpeg() {
        let src = write_temp("resize-in.mp4", &input);
        let dst = write_temp("resize-out.mp4", &out);
        assert_eq!(packet_times(&src), packet_times(&dst));
    }
}

#[test]
fn garbage_fails_without_wedging() {
    let mut c = Converter::new(false);
    c.push(&[0, 0, 0, 3, 1, 2, 3, 4, 5]);
    assert!(c.poll().is_err());
    let init = fixture("video-init.mp4");
    let o = Worker::new().append(&mut c, &init);
    assert!(!o.bytes.is_empty());
    let mut c = Converter::new(false);
    c.push(&fixture("video-0.m4s"));
    assert!(c.poll().is_err(), "media before init");
}

// ---------------------------------------------------------------- hostile

fn make_box(kind: [u8; 4], body: &[u8]) -> Vec<u8> {
    let mut out = ((body.len() + 8) as u32).to_be_bytes().to_vec();
    out.extend_from_slice(&kind);
    out.extend_from_slice(body);
    out
}

/// The boxes along `path` (each the first of its type in the one before),
/// as (start, end).
fn find_path(data: &[u8], path: &[&[u8; 4]]) -> Vec<(usize, usize)> {
    let mut chain = Vec::new();
    let (mut from, mut to) = (0, data.len());
    for kind in path {
        let mut pos = from;
        loop {
            assert!(pos + 8 <= to, "no {}", String::from_utf8_lossy(*kind));
            let size = u32::from_be_bytes(data[pos..pos + 4].try_into().unwrap()) as usize;
            if &data[pos + 4..pos + 8] == *kind {
                chain.push((pos, pos + size));
                from = pos + 8;
                to = pos + size;
                break;
            }
            pos += size;
        }
    }
    chain
}

/// Puts `new` at the end of the box at `path`, growing it and its parents.
fn insert(data: &[u8], path: &[&[u8; 4]], new: &[u8]) -> Vec<u8> {
    let chain = find_path(data, path);
    let at = chain.last().unwrap().1;
    let mut out = [&data[..at], new, &data[at..]].concat();
    for (start, end) in chain {
        let size = (end - start + new.len()) as u32;
        out[start..start + 4].copy_from_slice(&size.to_be_bytes());
    }
    out
}

fn set_u32(data: &mut [u8], at: usize, v: u32) {
    data[at..at + 4].copy_from_slice(&v.to_be_bytes());
}

/// Converts `input` and expects an error, quickly and without a panic.
fn expect_error(c: &mut Converter, input: &[u8]) -> String {
    let started = Instant::now();
    c.push(input);
    let mut w = Worker::new();
    let result = loop {
        match c.poll() {
            Ok(Poll::Job) => w.run_job(c),
            Ok(Poll::Idle) => break None,
            Err(e) => break Some(e.0),
        }
    };
    assert!(started.elapsed() < Duration::from_secs(5), "took {:?}", started.elapsed());
    result.expect("converted")
}

fn video_track_id() -> u32 {
    let init = fixture("video-init.mp4");
    let (tkhd, _) = *find_path(&init, &[b"moov", b"trak", b"tkhd"]).last().unwrap();
    u32::from_be_bytes(init[tkhd + 20..tkhd + 24].try_into().unwrap())
}

/// A moof+mdat for the video fixture's track with one trun.
fn fragment(trun_flags: u32, count: u32, trun_rest: &[u8], mdat: &[u8]) -> Vec<u8> {
    let tfhd = make_box(*b"tfhd", &[&0x20000u32.to_be_bytes()[..], &video_track_id().to_be_bytes()].concat());
    let tfdt = make_box(*b"tfdt", &[0, 0, 0, 0, 0, 0, 0, 0]);
    let trun = make_box(*b"trun", &[&trun_flags.to_be_bytes()[..], &count.to_be_bytes(), trun_rest].concat());
    let traf = make_box(*b"traf", &[tfhd, tfdt, trun].concat());
    let mfhd = make_box(*b"mfhd", &[0, 0, 0, 0, 0, 0, 0, 1]);
    let mut out = make_box(*b"moof", &[mfhd, traf].concat());
    out.extend(make_box(*b"mdat", mdat));
    out
}

#[test]
fn a_trun_with_billions_of_empty_samples_fails() {
    let mut c = Converter::new(false);
    Worker::new().append(&mut c, &fixture("video-init.mp4"));
    // No per-sample fields and no default size: four billion samples of
    // nothing, at 4 bytes of input.
    let e = expect_error(&mut c, &fragment(0, u32::MAX, &[], &[0; 16]));
    assert!(e.contains("too many samples"), "{e}");
    // The same with a default size: they'd run far past the mdat.
    let e = expect_error(&mut c, &fragment(0x200, 0x4000_0000, &[0; 8], &[0; 16]));
    assert!(e.contains("trun shorter") || e.contains("outside the mdat"), "{e}");
    // Huge samples.
    let e = expect_error(&mut c, &fragment(0x201, 2, &[&100u32.to_be_bytes()[..], &[0xff; 8]].concat(), &[0; 16]));
    assert!(e.contains("outside the mdat"), "{e}");
    // The converter still works.
    let o = Worker::new().append(&mut c, &fixture("video-0.m4s"));
    assert!(!o.bytes.is_empty());
}

#[test]
fn a_box_claiming_gigabytes_fails_at_once() {
    let mut c = Converter::new(false);
    let mut moof = make_box(*b"moof", &[0; 8]);
    set_u32(&mut moof, 0, 0xffff_fff0);
    let e = expect_error(&mut c, &moof);
    assert!(e.contains("too large"), "{e}");
}

/// The progressive fixture with one table changed.
fn patched(name: &str, table: [u8; 4], f: impl Fn(&mut [u8], usize)) -> Vec<u8> {
    let mut input = fixture(name);
    let (start, _) = *find_path(&input, &[b"moov", b"trak", b"mdia", b"minf", b"stbl", &table]).last().unwrap();
    f(&mut input, start + 8);
    input
}

#[test]
fn sample_tables_with_huge_counts_fail_or_finish() {
    // A fixed sample size and a count of two billion.
    let input = patched("progressive.mp4", *b"stsz", |d, body| {
        set_u32(d, body + 4, 1);
        set_u32(d, body + 8, 0x7fff_ffff);
    });
    let e = expect_error(&mut Converter::new(true), &input);
    assert!(e.contains("too many samples"), "{e}");
    // ctts runs of four billion samples, over and over.
    let input = patched("progressive.mp4", *b"ctts", |d, body| {
        let entries = u32::from_be_bytes(d[body + 4..body + 8].try_into().unwrap()) as usize;
        for i in 0..entries {
            set_u32(d, body + 8 + i * 8, u32::MAX);
        }
    });
    let started = Instant::now();
    let mut c = Converter::new(true);
    let out = convert(&mut c, &mut Worker::new(), &input, input.len());
    assert!(started.elapsed() < Duration::from_secs(5));
    // The decoder puts frames out in an order the timestamps now disagree
    // with; what's written still never goes back.
    if has_ffmpeg() {
        assert_decode_order(&write_temp("ctts-out.mp4", &out));
    }
}

#[test]
fn chunk_offsets_near_the_end_of_u64_fail() {
    // gif.mp4 has its moov last, so it can grow without moving the media.
    let input = fixture("gif.mp4");
    let path: [&[u8; 4]; 5] = [b"moov", b"trak", b"mdia", b"minf", b"stbl"];
    let (stco, _) = *find_path(&input, &[b"moov", b"trak", b"mdia", b"minf", b"stbl", b"stco"]).last().unwrap();
    let chunks = u32::from_be_bytes(input[stco + 12..stco + 16].try_into().unwrap());
    let mut input = input.clone();
    input[stco + 4..stco + 8].copy_from_slice(b"free");
    let mut co64 = vec![0, 0, 0, 0];
    co64.extend(chunks.to_be_bytes());
    for i in 0..u64::from(chunks) {
        co64.extend((u64::MAX - 1000 + i * 10).to_be_bytes());
    }
    let input = insert(&input, &path, &make_box(*b"co64", &co64));
    let e = expect_error(&mut Converter::new(true), &input);
    assert!(e.contains("end of any file"), "{e}");
}

#[test]
fn boxes_nested_without_end_fail() {
    let init = fixture("video-init.mp4");
    let mut nested = make_box(*b"stbl", &[]);
    for _ in 0..100 {
        nested = make_box(*b"stbl", &nested);
    }
    let input = insert(&init, &[b"moov", b"trak", b"mdia", b"minf", b"stbl"], &nested);
    let e = expect_error(&mut Converter::new(false), &input);
    assert!(e.contains("nested too deep"), "{e}");
}

#[test]
fn progressive_files_leave_out_tracks_that_wont_play() {
    // gif.mp4's video trak again, as a timecode track, as MP3 audio, and
    // as Opus, which plays as it is.
    let input = fixture("gif.mp4");
    let (trak_start, trak_end) = find_path(&input, &[b"moov", b"trak"])[1];
    let trak = input[trak_start..trak_end].to_vec();
    let variant = |id: u32, handler: &[u8; 4], entry: &[u8; 4]| {
        let mut t = trak.clone();
        let (tkhd, _) = find_path(&t, &[b"trak", b"tkhd"])[1];
        set_u32(&mut t, tkhd + 20, id);
        let (hdlr, _) = find_path(&t, &[b"trak", b"mdia", b"hdlr"])[2];
        t[hdlr + 16..hdlr + 20].copy_from_slice(handler);
        let (stsd, _) = find_path(&t, &[b"trak", b"mdia", b"minf", b"stbl", b"stsd"])[4];
        t[stsd + 20..stsd + 24].copy_from_slice(entry);
        t
    };
    let mut file = input.clone();
    for (id, handler, entry) in [(7, b"tmcd", b"tmcd"), (8, b"soun", b"mp4a"), (9, b"soun", b"Opus")] {
        file = insert(&file, &[b"moov"], &variant(id, handler, entry));
    }
    let mut c = Converter::new(true);
    let out = convert(&mut c, &mut Worker::new(), &file, file.len());
    assert_eq!(c.mime, "video/mp4; codecs=\"vp09.00.41.08,opus\"");
    // Two traks in the converted moov, and a trex each.
    assert_eq!(count(&out, *b"trak"), 2);
    assert_eq!(count(&out, *b"trex"), 2);
    // Video that can't be converted fails the file rather than playing its
    // sound alone.
    let hevc = insert(&input, &[b"moov"], &variant(9, b"soun", b"Opus"));
    let (stsd, _) = find_path(&hevc, &[b"moov", b"trak", b"mdia", b"minf", b"stbl", b"stsd"])[5];
    let mut hevc = hevc.clone();
    hevc[stsd + 20..stsd + 24].copy_from_slice(b"hvc1");
    let e = expect_error(&mut Converter::new(true), &hevc);
    assert!(e.contains("no H.264 video"), "{e}");
}

/// Real site media can't be committed. Point `MBGA_MEDIA_SAMPLES` at a
/// folder with X's CMAF (vinit.mp4, v0.m4s…, ainit.mp4, a0.m4s…) and
/// progressive files (v.mp4, gif.mp4) to run them through too.
#[test]
fn local_samples() {
    let Ok(dir) = std::env::var("MBGA_MEDIA_SAMPLES") else {
        return;
    };
    let dir = Path::new(&dir);
    let read = |name: &str| std::fs::read(dir.join(name)).ok();
    for (init, prefix) in [("vinit.mp4", "v"), ("ainit.mp4", "a")] {
        let Some(mut input) = read(init) else { continue };
        let mut c = Converter::new(false);
        let mut w = Worker::new();
        let mut out = w.append(&mut c, &input).bytes;
        for i in 0.. {
            let Some(seg) = read(&format!("{prefix}{i}.m4s")) else { break };
            let o = w.append(&mut c, &seg);
            out.extend(o.held);
            out.extend(o.bytes);
            input.extend(seg);
        }
        let o = w.drain(&mut c);
        out.extend(o.held);
        let src = write_temp(&format!("local-{prefix}-in.mp4"), &input);
        let dst = write_temp(&format!("local-{prefix}-out.mp4"), &out);
        // X's video uses negative composition offsets, which ffmpeg reads
        // shifted by the largest one; compare the timelines' shapes.
        assert_eq!(relative(packet_times(&src)), relative(packet_times(&dst)), "{init}");
        assert_eq!(w.decode_only, 0);
    }
    for name in ["v.mp4", "gif.mp4"] {
        let Some(input) = read(name) else { continue };
        let mut c = Converter::new(true);
        let out = convert(&mut c, &mut Worker::new(), &input, 65536);
        let src = write_temp(&format!("local-{name}"), &input);
        let dst = write_temp(&format!("local-out-{name}"), &out);
        assert_eq!(relative(packet_times(&src)), relative(packet_times(&dst)), "{name}");
    }
}

// ------------------------------------------------------------- round two

/// What worker.js does when a module instance grew too big: a fresh one,
/// primed with the init and given the old one's state.
fn recycle(c: &mut Converter) -> bool {
    if !c.recyclable() {
        return false;
    }
    c.save_state();
    let state = c.state.clone();
    let mut fresh = Converter::new(false);
    fresh.push(&c.init);
    assert_eq!(fresh.poll().unwrap(), Poll::Idle);
    fresh.clear_output();
    fresh.load_state(&state).unwrap();
    *c = fresh;
    true
}

/// The midgop fixture's first half, a drain, and the rest, recycling the
/// converter after the drain if `recycling`.
fn drain_midway(recycling: bool) -> (Vec<u8>, usize, bool) {
    let input = fixture("midgop.mp4");
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    let second = input.windows(4).enumerate().filter(|(_, w)| w == b"moof").nth(1).unwrap().0 - 4;
    let mut out = Vec::new();
    let o = w.append(&mut c, &input[..second]);
    out.extend(o.held);
    out.extend(o.bytes);
    let o = w.drain(&mut c);
    out.extend(o.held);
    let recycled = recycling && recycle(&mut c);
    let o = w.append(&mut c, &input[second..]);
    out.extend(o.held);
    out.extend(o.bytes);
    let o = w.drain(&mut c);
    out.extend(o.held);
    (out, w.decode_only, recycled)
}

#[test]
fn a_recycled_converter_carries_on_mid_gop() {
    let (want, want_replayed, _) = drain_midway(false);
    let (got, replayed, recycled) = drain_midway(true);
    assert!(recycled, "not recyclable after a drain");
    // The fresh converter replays the GOP as the old one would have, rather
    // than dropping the fragment's frames up to the next keyframe.
    assert!(want_replayed > 0);
    assert_eq!(replayed, want_replayed);
    assert_eq!(chunk_times(&got), chunk_times(&want));
    assert_eq!(got, want);
}

#[test]
fn recycling_keeps_segments_and_sizes() {
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    w.append(&mut c, &fixture("video-init.mp4"));
    // Smaller frames from the start: the converted init says so.
    w.size = (160, 90);
    let mut times = Vec::new();
    let mut moovs = 0;
    for i in 0..3 {
        let o = w.append(&mut c, &fixture(&format!("video-{i}.m4s")));
        moovs += count(&o.bytes, *b"moov");
        times.extend(chunk_times(&o.bytes));
        // Every segment starts with a keyframe and is flushed, so nothing
        // waits.
        assert!(recycle(&mut c), "segment {i}");
    }
    // The size carried over: no new init after recycling.
    assert_eq!(moovs, 1);
    assert_eq!(times.len(), 90);
}

#[test]
fn aac_streams_recycle_only_before_decoding() {
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    w.append(&mut c, &fixture("aac-init.mp4"));
    assert!(c.recyclable());
    w.append(&mut c, &fixture("aac-0.m4s"));
    // The AAC decoder's overlap can't move to a new one: it would click.
    assert!(!c.recyclable());
    c.reset();
    assert!(c.recyclable());
}

#[test]
fn a_fragment_appended_again_keeps_its_frames() {
    // hls.js switching levels at once: remove() the current fragment, then
    // append it again, without abort(). The decoder still holds the first
    // copy's last frames, with the same timestamps as the second's.
    let units = units(&fixture("midgop.mp4"));
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    for u in &units[..4] {
        w.append(&mut c, u);
    }
    let first_copy = w.seq;
    // units[3] runs from the keyframe at 1 s (shown at 1.067 s) for half a
    // second.
    let range = 1_060_000..1_560_000;
    let mut again = Vec::new();
    let mut late = Vec::new();
    let mut collect = |o: &Output, seq: f64| {
        for g in &o.groups {
            let times = chunk_times(&o.held[g.offset as usize..(g.offset + g.len) as usize]);
            if g.seq.to_bits() == first_copy.to_bits() {
                late.extend(times);
            } else {
                again.extend(times.into_iter().filter(|t| range.contains(t)));
            }
        }
        if seq > first_copy {
            again.extend(chunk_times(&o.bytes).into_iter().filter(|t| range.contains(t)));
        }
    };
    let o = w.append(&mut c, &units[3]);
    collect(&o, w.seq);
    for u in &units[4..] {
        let o = w.append(&mut c, u);
        collect(&o, w.seq);
    }
    let o = w.drain(&mut c);
    collect(&o, w.seq);
    // The first copy's held frames come out for it, and the second copy
    // has every one of its frames.
    assert!(!late.is_empty());
    assert!(late.iter().all(|t| range.contains(t)));
    again.sort_unstable();
    again.dedup();
    assert_eq!(again.len(), 15, "{again:?}");
}

#[test]
fn a_frame_rate_cap_stretches_the_frames_kept() {
    let input = fixture("midgop.mp4");
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    // 15 fps from 30.
    w.cap = Some(66_667);
    let out = convert(&mut c, &mut w, &input, input.len());
    let times = chunk_times(&out);
    assert!((29..=32).contains(&times.len()), "{} frames", times.len());
    // Keyframes are always kept (the first frame is shown at 1024/15360 s).
    assert!(times.contains(&66_667) && times.contains(&1_066_667), "{times:?}");
    // The kept frames last as long as all of them did, with no holes: each
    // fragment starts where the one before ended.
    let mut end = None;
    let mut total = 0;
    for (base, durations) in fragment_spans(&out) {
        assert!(end.is_none_or(|e| e == base), "hole before {base}");
        let sum: i64 = durations.iter().map(|&d| i64::from(d)).sum();
        end = Some(base + sum);
        total += sum;
    }
    assert_eq!(total, 60 * 512);
    if has_ffmpeg() {
        assert_decode_order(&write_temp("cap-out.mp4", &out));
    }
}

/// Each fragment's base decode time and sample durations, as written here
/// (one track, tfdt version 1, trun with every field).
fn fragment_spans(data: &[u8]) -> Vec<(i64, Vec<u32>)> {
    let mut out = Vec::new();
    let mut pos = 0;
    while let Some(at) = data[pos..].windows(4).position(|w| w == b"tfdt") {
        let tfdt = pos + at + 4;
        let base = u64::from_be_bytes(data[tfdt + 4..tfdt + 12].try_into().unwrap()) as i64;
        let trun = tfdt + data[tfdt..].windows(4).position(|w| w == b"trun").unwrap() + 4;
        let count = u32::from_be_bytes(data[trun + 4..trun + 8].try_into().unwrap()) as usize;
        let durations = (0..count)
            .map(|i| u32::from_be_bytes(data[trun + 12 + i * 16..trun + 16 + i * 16].try_into().unwrap()))
            .collect();
        out.push((base, durations));
        pos = trun;
    }
    out
}

#[test]
fn natural_size_is_the_inputs_display_size() {
    let mut c = Converter::new(false);
    let o = Worker::new().append(&mut c, &fixture("video-init.mp4"));
    assert_eq!(o.inits, 1);
    assert_eq!(c.natural(), Some((320, 180)));
    // Wide pixels, 4:3, in the entry's pasp: wider. Narrow ones: taller.
    for (h, v, natural) in [(4, 3, (427, 180)), (3, 4, (320, 240))] {
        let mut init = fixture("video-init.mp4");
        let pasp = init.windows(4).position(|w| w == b"pasp").unwrap() + 4;
        set_u32(&mut init, pasp, h);
        set_u32(&mut init, pasp + 4, v);
        let mut c = Converter::new(false);
        Worker::new().append(&mut c, &init);
        assert_eq!(c.natural(), Some(natural));
    }
}

/// A progressive file with one Opus track of `count` one-byte samples,
/// `delta` ticks apart at `timescale`, the last lasting `last` ticks.
#[allow(clippy::similar_names)]
fn opus_file(count: u32, delta: u32, timescale: u32, last: u32) -> Vec<u8> {
    opus_file_of(count, delta, timescale, last, 1)
}

/// The same with `size`-byte samples.
#[allow(clippy::similar_names)]
fn opus_file_of(count: u32, delta: u32, timescale: u32, last: u32, size: u32) -> Vec<u8> {
    let full = |kind: [u8; 4], body: &[u8]| make_box(kind, &[&[0u8; 4][..], body].concat());
    let ftyp = make_box(*b"ftyp", b"isom\0\0\0\0isom");
    let mdat_header = 8;
    let data_at = (ftyp.len() + mdat_header) as u32;
    let mdat = make_box(*b"mdat", &vec![0x55; (count * size) as usize]);
    // Version 0: the track id, and the timescale, 12 bytes into the body.
    let mut tkhd = [0u8; 84];
    tkhd[12..16].copy_from_slice(&1u32.to_be_bytes());
    let mut mdhd = [0u8; 24];
    mdhd[12..16].copy_from_slice(&timescale.to_be_bytes());
    let hdlr = full(*b"hdlr", &[&[0u8; 4][..], b"soun", &[0u8; 13]].concat());
    let mut entry = vec![0u8; 28];
    entry[7] = 1;
    entry[17] = 2;
    entry[19] = 16;
    entry[24..28].copy_from_slice(&(48000u32 << 16).to_be_bytes());
    entry.extend(make_box(*b"dOps", &[0, 2, 0x01, 0x38, 0, 0, 0xbb, 0x80, 0, 0, 0]));
    let stsd = full(*b"stsd", &[&1u32.to_be_bytes()[..], &make_box(*b"Opus", &entry)].concat());
    let mut stts = 2u32.to_be_bytes().to_vec();
    for (n, d) in [(count - 1, delta), (1, last)] {
        stts.extend(n.to_be_bytes());
        stts.extend(d.to_be_bytes());
    }
    let stts = full(*b"stts", &stts);
    let stsc = full(*b"stsc", &[1u32, 1, count, 1].iter().flat_map(|v| v.to_be_bytes()).collect::<Vec<u8>>());
    let stsz = full(*b"stsz", &[size, count].iter().flat_map(|v| v.to_be_bytes()).collect::<Vec<u8>>());
    let stco = full(*b"stco", &[1u32, data_at].iter().flat_map(|v| v.to_be_bytes()).collect::<Vec<u8>>());
    let stbl = make_box(*b"stbl", &[stsd, stts, stsc, stsz, stco].concat());
    let minf = make_box(*b"minf", &stbl);
    let mdia = make_box(*b"mdia", &[full(*b"mdhd", &mdhd[4..]), hdlr, minf].concat());
    let trak = make_box(*b"trak", &[full(*b"tkhd", &tkhd[4..]), mdia].concat());
    let moov = make_box(*b"moov", &[full(*b"mvhd", &[0u8; 96]), trak].concat());
    [ftyp, mdat, moov].concat()
}

#[test]
fn a_sample_lasting_years_doesnt_plan_billions_of_fragments() {
    // At a timescale of 1, the last sample claims 136 years.
    let input = opus_file(100, 1, 1, u32::MAX);
    let started = Instant::now();
    let mut c = Converter::new(true);
    let out = convert(&mut c, &mut Worker::new(), &input, input.len());
    assert!(started.elapsed() < Duration::from_secs(5), "took {:?}", started.elapsed());
    assert_eq!(c.mime, "audio/mp4; codecs=\"opus\"");
    // Fragments of about two seconds, and the last.
    assert!((45..=55).contains(&count(&out, *b"moof")), "{} fragments", count(&out, *b"moof"));
}

#[test]
fn long_files_stream_in_linear_time() {
    // Half a million samples, 50 a second: 5,000 fragments.
    let input = opus_file(500_000, 1, 50, 1);
    let started = Instant::now();
    let mut c = Converter::new(true);
    let out = convert(&mut c, &mut Worker::new(), &input, 1 << 20);
    assert!(started.elapsed() < Duration::from_secs(5), "took {:?}", started.elapsed());
    assert!((4900..=5000).contains(&count(&out, *b"moof")), "{} fragments", count(&out, *b"moof"));
}

#[test]
fn an_init_lost_with_a_failed_append_comes_again() {
    // A file whose timestamps run out of range a few fragments in: the
    // append fails, and the page never gets its output, init and all.
    let mut input = fixture("progressive.mp4");
    let mdhd = find_path(&input, &[b"moov", b"trak", b"mdia", b"mdhd"]).last().unwrap().0;
    set_u32(&mut input, mdhd + 20, 1);
    let stts = find_path(&input, &[b"moov", b"trak", b"mdia", b"minf", b"stbl", b"stts"]).last().unwrap().0;
    set_u32(&mut input, stts + 20, u32::MAX);
    let mut c = Converter::new(true);
    let mut w = Worker::new();
    w.seq += 1.0;
    c.begin(w.seq);
    c.push(&input);
    let e = loop {
        match c.poll() {
            Ok(Poll::Job) => w.run_job(&mut c),
            Ok(Poll::Idle) => panic!("converted"),
            Err(e) => break e.0,
        }
    };
    assert!(e.contains("out of range") && w.jobs > 0, "{e} after {} jobs", w.jobs);
    c.discard_output();
    // The frames the decoder still held come with the init before them.
    let o = w.drain(&mut c);
    assert!(!o.held.is_empty());
    let at = |kind: &[u8]| o.held.windows(4).position(|w| w == kind).unwrap();
    assert!(at(b"moov") < at(b"moof"));
}

// ----------------------------------------------------------- round three

/// The frames in an output, held groups first, with the append each came
/// for.
fn frames_by_seq(o: &Output, seq: f64) -> Vec<(f64, i64)> {
    let mut out = Vec::new();
    for g in &o.groups {
        let times = chunk_times(&o.held[g.offset as usize..(g.offset + g.len) as usize]);
        out.extend(times.into_iter().map(|t| (g.seq, t)));
    }
    out.extend(chunk_times(&o.bytes).into_iter().map(|t| (seq, t)));
    out
}

#[test]
fn a_different_init_over_the_same_times_keeps_both_streams_frames_apart() {
    // An ABR switch that replaces what's buffered: a new init (here only
    // its creation time differs), then the same times again, while the
    // decoder still holds frames of the old stream at those times.
    let units = units(&fixture("midgop.mp4"));
    let mut init = units[0].clone();
    let (mvhd, _) = *find_path(&init, &[b"moov", b"mvhd"]).last().unwrap();
    set_u32(&mut init, mvhd + 12, 12345);
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    let mut frames = Vec::new();
    for u in &units[..3] {
        let o = w.append(&mut c, u);
        frames.extend(frames_by_seq(&o, w.seq));
    }
    let old_last = w.seq;
    let o = w.append(&mut c, &init);
    // The old stream's frames come out now, for the appends they came in,
    // before the new init.
    assert!(!o.groups.is_empty(), "the old frames weren't finished");
    assert!(o.groups.iter().all(|g| g.seq <= old_last));
    assert_eq!(count(&o.bytes, *b"moov"), 1);
    assert!(chunk_times(&o.bytes).is_empty());
    frames.extend(frames_by_seq(&o, w.seq));
    let first_new = w.seq + 1.0;
    for u in &units[1..] {
        let o = w.append(&mut c, u);
        frames.extend(frames_by_seq(&o, w.seq));
    }
    let o = w.drain(&mut c);
    frames.extend(frames_by_seq(&o, w.seq));
    let old: BTreeSet<i64> = frames.iter().filter(|f| f.0 < first_new).map(|f| f.1).collect();
    let new: Vec<i64> = frames.iter().filter(|f| f.0 >= first_new).map(|f| f.1).collect();
    // Every frame of the two old fragments, and every frame of the new
    // stream, its first keyframe included, once.
    assert_eq!(old.len(), 30, "{old:?}");
    assert_eq!(new.len(), 60, "{new:?}");
    assert_eq!(new.iter().collect::<BTreeSet<_>>().len(), 60);
    assert!(new.contains(&66_667), "the new stream's first keyframe is lost");
}

#[test]
fn natural_size_comes_with_the_first_init_and_where_frames_change_it() {
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    let o = w.append(&mut c, &fixture("video-init.mp4"));
    // The first comes with the init, before any frame, and applies at once.
    assert_eq!(o.natural, Some(Natural { width: 320, height: 180, at: None, seq: 1.0 }));
    // The SPS (avc3) doubles the size from the keyframe at 1 s.
    w.revisible = Some((1_000_000, (640, 360)));
    let mut naturals = Vec::new();
    for i in 0..3 {
        let o = w.append(&mut c, &fixture(&format!("video-{i}.m4s")));
        naturals.extend(o.natural.map(|n| (w.seq, n)));
    }
    assert_eq!(naturals.len(), 1, "{naturals:?}");
    let (seq, n) = naturals[0];
    assert_eq!((n.width, n.height, n.seq), (640, 360, seq));
    let at = n.at.unwrap();
    assert!((1.0..1.1).contains(&at), "at {at}");
    // The page may have lost it with an aborted append: again, at once.
    c.reset();
    let o = w.append(&mut c, &fixture("video-2.m4s"));
    assert_eq!(o.natural.map(|n| (n.width, n.height, n.at)), Some((640, 360, None)));
}

#[test]
fn the_output_says_what_times_it_covers() {
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    let o = w.append(&mut c, &fixture("video-init.mp4"));
    assert_eq!(o.range, None, "an init has no times");
    let mut last_end = None;
    for i in 0..3 {
        let o = w.append(&mut c, &fixture(&format!("video-{i}.m4s")));
        let (start, end) = o.range.unwrap();
        assert!((end - start - 1.0).abs() < 0.01, "{start}..{end}");
        assert!(last_end.is_none_or(|e: f64| (e - start).abs() < 1e-6), "{last_end:?} then {start}");
        last_end = Some(end);
    }
    // Muxed: both tracks' times.
    let mut c = Converter::new(false);
    let o = Worker::new().append(&mut c, &fixture("muxed.mp4"));
    let (start, end) = o.range.unwrap();
    assert!(start < 0.1 && end > 1.9, "{start}..{end}");
}

#[test]
fn a_progressive_file_starts_at_the_keyframe_before_start() {
    // Keyframes every second; start at 1.2 s, from the one at 1 s.
    let input = fixture("progressive.mp4");
    let mut c = Converter::new(true);
    c.set_start(1.2);
    let mut w = Worker::new();
    let out = convert(&mut c, &mut w, &input, 4096);
    let times = chunk_times(&out);
    assert_eq!(times.len(), 30, "{times:?}");
    assert!(times.iter().all(|&t| t >= 1_000_000), "{times:?}");
    // Nothing before it was decoded.
    assert_eq!(w.encoded, 30);
    if has_ffmpeg() {
        let dst = write_temp("start-out.mp4", &out);
        assert_decode_order(&dst);
        // Audio from the keyframe on, too, with one frame before it.
        let audio = &packet_times(&dst)[1].1;
        let first: i64 = audio.iter().map(|t| t.parse::<i64>().unwrap()).min().unwrap();
        assert!((40_000..44_100).contains(&first), "audio starts at {first}");
    }
}

/// Streams `file` in `step`-byte appends that say where they start, the
/// way the shim does: after a reply with `need` it goes on from there, and
/// the append it had already sent is dropped.
fn stream_file(c: &mut Converter, w: &mut Worker, file: &[u8], step: usize) -> (Vec<u8>, Vec<u64>) {
    let mut out = Vec::new();
    let mut needs = Vec::new();
    let mut pos = 0;
    while pos < file.len() {
        let end = (pos + step).min(file.len());
        let o = w.append_at(c, &file[pos..end], pos as u64).expect("dropped");
        out.extend(o.held);
        out.extend(o.bytes);
        // Never the whole of a big mdat: at most a fragment's worth.
        assert!(c.input.len() < 1 << 20, "{} bytes waiting", c.input.len());
        match o.need {
            Some(need) => {
                needs.push(need);
                if end < file.len() {
                    // Sent before the shim heard: dropped, with an empty reply.
                    assert!(w.append_at(c, &file[end..(end + step).min(file.len())], end as u64).is_none());
                }
                pos = usize::try_from(need).unwrap();
            }
            None => pos = end,
        }
    }
    let o = w.drain(c);
    out.extend(o.held);
    (out, needs)
}

#[test]
fn a_progressive_file_asks_for_the_bytes_it_needs() {
    let input = fixture("progressive.mp4");
    let mut c = Converter::new(true);
    c.set_start(1.2);
    let mut w = Worker::new();
    let (out, needs) = stream_file(&mut c, &mut w, &input, 4096);
    assert_eq!(needs.len(), 1, "{needs:?}");
    let times = chunk_times(&out);
    assert_eq!(times.len(), 30);
    assert!(times.iter().all(|&t| t >= 1_000_000));
    // Without a start, the bytes run on and nothing is asked for.
    let mut c = Converter::new(true);
    let (out, needs) = stream_file(&mut c, &mut Worker::new(), &input, 4096);
    assert!(needs.is_empty());
    assert_eq!(chunk_times(&out).len(), 60);
}

#[test]
fn a_big_file_with_its_moov_last_asks_for_it_then_for_its_samples() {
    // 4 MB of samples, then the moov.
    let file = opus_file_of(1000, 1, 50, 1, 4096);
    let moov_at = find_path(&file, &[b"moov"])[0].0;
    let mut c = Converter::new(true);
    let (out, needs) = stream_file(&mut c, &mut Worker::new(), &file, 65536);
    let ftyp_and_mdat_header = 20 + 8;
    assert_eq!(needs, [moov_at as u64, ftyp_and_mdat_header], "moov at {moov_at}");
    // Two-second fragments of 50 samples a second, all there.
    assert_eq!(count(&out, *b"moof"), 10);
    // A small one just streams through.
    let file = opus_file_of(100, 1, 50, 1, 4096);
    let mut c = Converter::new(true);
    let (out, needs) = stream_file(&mut c, &mut Worker::new(), &file, 65536);
    assert!(needs.is_empty());
    assert_eq!(count(&out, *b"moof"), 1);
}

#[test]
fn an_avc3_stream_whose_sps_changes_its_size() {
    let units = units(&fixture("avc3.mp4"));
    let mut c = Converter::new(false);
    let mut w = Worker::new();
    // The decoder puts the second second out at 480x270, as its SPS says
    // (from 16384/15360 s).
    w.revisible = Some((1_066_667, (480, 270)));
    let mut naturals = Vec::new();
    let mut out = Vec::new();
    for u in &units {
        let o = w.append(&mut c, u);
        naturals.extend(o.natural);
        out.extend(o.held);
        out.extend(o.bytes);
    }
    let o = w.drain(&mut c);
    naturals.extend(o.natural);
    out.extend(o.held);
    assert_eq!(chunk_times(&out).len(), 60);
    assert_eq!(naturals.len(), 2, "{naturals:?}");
    assert_eq!((naturals[0].width, naturals[0].height, naturals[0].at), (320, 180, None));
    assert_eq!((naturals[1].width, naturals[1].height), (480, 270));
    let at = naturals[1].at.unwrap();
    assert!((1.0..1.1).contains(&at), "at {at}");
}
