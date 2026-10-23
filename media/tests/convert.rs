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

use mbga_media::{Converter, Poll, DECODE_ONLY, FLUSH, KEY};

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)).unwrap()
}

/// What worker.js keeps per video track.
#[derive(Default)]
struct Decoder {
    /// Decoded frames the decoder hasn't put out yet, by timestamp.
    waiting: BTreeSet<i64>,
    /// Decode-only frames, keyframes, and whether decoding started.
    skip: BTreeSet<i64>,
    keys: BTreeSet<i64>,
    started: bool,
    encoder_started: bool,
}

/// The worker: decoders that put frames out in presentation order once
/// more than `reorder` wait, or at a keyframe or a flush; an encoder that
/// takes them in that order and makes a keyframe where the input has one.
struct Worker {
    reorder: usize,
    decoders: BTreeMap<u32, Decoder>,
    decode_only: usize,
    jobs: usize,
    /// The coded size of each chunk, and from which timestamp on to use
    /// another (as when the page's video gets smaller).
    size: (u16, u16),
    resize: Option<(i64, (u16, u16))>,
}

impl Worker {
    fn new() -> Self {
        Worker { reorder: 4, decoders: BTreeMap::new(), decode_only: 0, jobs: 0, size: (320, 180), resize: None }
    }

    fn put_out(&mut self, c: &mut Converter, track: u32, ts: i64) {
        let d = self.decoders.get_mut(&track).unwrap();
        d.waiting.remove(&ts);
        if d.skip.remove(&ts) {
            return;
        }
        let key = d.keys.remove(&ts) || !d.encoder_started;
        // Sizes change at keyframes only.
        if let Some((from, size)) = self.resize.filter(|&(from, _)| ts >= from && key) {
            let _ = from;
            self.size = size;
            self.resize = None;
        }
        if !c.frame(track, ts as f64) {
            return;
        }
        d.encoder_started = true;
        c.chunk(track, ts as f64, key, self.size, format!("vp9 {ts}").into_bytes()).unwrap();
    }

    fn decode(&mut self, c: &mut Converter, track: u32, ts: i64, flags: u32) {
        let d = self.decoders.entry(track).or_default();
        assert!(d.started || flags & KEY != 0, "decoding starts without a keyframe");
        d.started = true;
        if flags & KEY != 0 {
            // An IDR picture: everything before it comes out first.
            let before: Vec<i64> = d.waiting.iter().copied().collect();
            for ts in before {
                self.put_out(c, track, ts);
            }
        }
        let d = self.decoders.get_mut(&track).unwrap();
        d.waiting.insert(ts);
        if flags & DECODE_ONLY != 0 {
            d.skip.insert(ts);
            self.decode_only += 1;
        }
        if flags & KEY != 0 {
            d.keys.insert(ts);
        }
        while self.decoders[&track].waiting.len() > self.reorder {
            let first = *self.decoders[&track].waiting.first().unwrap();
            self.put_out(c, track, first);
        }
    }

    fn flush(&mut self, c: &mut Converter, track: u32) {
        let waiting: Vec<i64> =
            self.decoders.get(&track).map(|d| d.waiting.iter().copied().collect()).unwrap_or_default();
        for ts in waiting {
            self.put_out(c, track, ts);
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
            let data = &job.data[s.offset as usize..(s.offset + s.len) as usize];
            assert_eq!(&data[..4], &[0, 0, 0, 1], "not Annex-B");
            assert!(s.codec >> 16 == 0x64 || s.codec >> 16 == 0x4d, "codec {:x}", s.codec);
            assert!(s.bitrate > 0);
            if s.flags & FLUSH != 0 {
                flush.insert(s.track);
            }
        }
        for s in &samples {
            self.decode(c, s.track, s.timestamp as i64, s.flags);
        }
        for track in flush {
            self.flush(c, track);
        }
        c.write().unwrap();
    }

    /// One append: the bytes it gives back, `held` first.
    fn append(&mut self, c: &mut Converter, bytes: &[u8]) -> Output {
        c.begin();
        c.push(bytes);
        loop {
            match c.poll() {
                Ok(Poll::Idle) => break,
                Ok(Poll::Job) => self.run_job(c),
                Err(e) => panic!("{e}"),
            }
        }
        c.write().unwrap();
        Output { held: std::mem::take(&mut c.held), bytes: std::mem::take(&mut c.output) }
    }

    /// Before `endOfStream()`: everything the decoders still hold.
    fn drain(&mut self, c: &mut Converter) -> Output {
        c.begin();
        let tracks: Vec<u32> = self.decoders.keys().copied().collect();
        for track in tracks {
            self.flush(c, track);
        }
        c.write().unwrap();
        Output { held: std::mem::take(&mut c.held), bytes: std::mem::take(&mut c.output) }
    }
}

struct Output {
    held: Vec<u8>,
    bytes: Vec<u8>,
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
    let mut out = Vec::new();
    let mut helds = 0;
    for unit in &units {
        let o = w.append(&mut c, unit);
        let (held, own) = (chunk_times(&o.held), chunk_times(&o.bytes));
        if !held.is_empty() {
            helds += 1;
            // What belongs to an earlier append comes before this one's.
            assert!(held.iter().max() < own.iter().min().or(Some(&i64::MAX)), "{held:?} then {own:?}");
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
