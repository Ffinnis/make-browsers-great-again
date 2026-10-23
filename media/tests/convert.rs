//! Runs the fixtures through the converter, standing in for the worker:
//! video jobs get fake "VP9" chunks named after their timestamps, so the
//! fragments' timing can be checked here without `WebCodecs`. Where ffmpeg is
//! installed, its demuxer and FLAC decoder check the output independently.

// Helpers here are test code too.
#![allow(clippy::unwrap_used)]

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use std::collections::BTreeMap;

use mbga_media::{Converter, Poll, DECODE_ONLY, KEY, UNHELD};

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)).unwrap()
}

/// Feeds `input` in `step`-byte appends and runs every job. Returns the
/// output and how many samples were decode-only.
fn convert(c: &mut Converter, input: &[u8], step: usize) -> (Vec<u8>, usize) {
    convert_holding(c, input, step, &mut BTreeMap::new())
}

/// The same, with the frames the worker would be holding between jobs.
fn convert_holding(c: &mut Converter, input: &[u8], step: usize, held: &mut Held) -> (Vec<u8>, usize) {
    let mut out = Vec::new();
    let mut decode_only = 0;
    for piece in input.chunks(step) {
        c.push(piece);
        loop {
            match c.poll() {
                Ok(Poll::Idle) => break,
                Ok(Poll::Job) => decode_only += run_job(c, held),
                Err(e) => panic!("{e}"),
            }
        }
        out.append(&mut c.output);
    }
    (out, decode_only)
}

/// Per track, the timestamps of frames decoded but not yet encoded.
type Held = BTreeMap<u32, BTreeSet<i64>>;

/// Does what worker.js does with a job, with "VP9" chunks named after their
/// frames: decode-only samples are dropped, frames from `hold_from` on wait
/// for the next job, and encoding goes in timestamp order.
fn run_job(c: &mut Converter, held: &mut Held) -> usize {
    let job = c.job().unwrap();
    let samples = job.samples.clone();
    let mut started = BTreeSet::new();
    let mut decode_only = 0;
    let mut decoded: BTreeMap<u32, (f64, BTreeSet<i64>)> = BTreeMap::new();
    for s in &samples {
        // The decoder must start each track on a keyframe.
        if started.insert(s.track) {
            assert!(s.flags & KEY != 0, "job starts without a keyframe");
            if s.flags & UNHELD != 0 {
                held.remove(&s.track);
            }
        }
        let data = &job.data[s.offset as usize..(s.offset + s.len) as usize];
        assert_eq!(&data[..4], &[0, 0, 0, 1], "not Annex-B");
        assert!(s.codec >> 16 == 0x64 || s.codec >> 16 == 0x4d, "codec {:x}", s.codec);
        assert!(s.bitrate > 0);
        let entry = decoded.entry(s.track).or_insert((s.hold_from, BTreeSet::new()));
        if s.flags & DECODE_ONLY != 0 {
            decode_only += 1;
        } else {
            entry.1.insert(s.timestamp as i64);
        }
    }
    for (track, (hold_from, frames)) in decoded {
        let waiting = held.entry(track).or_default();
        waiting.extend(frames);
        let later = waiting.split_off(&(hold_from.min(9e15) as i64));
        for (i, ts) in std::mem::replace(waiting, later).into_iter().enumerate() {
            c.chunk(track, ts as f64, i == 0, format!("vp9 {ts}").as_bytes()).unwrap();
        }
    }
    c.finish().unwrap();
    decode_only
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

#[test]
fn muxed_cmaf_keeps_every_frame_and_its_time() {
    let input = fixture("muxed.mp4");
    let mut c = Converter::new(false);
    // Odd-sized appends split boxes everywhere.
    let (out, decode_only) = convert(&mut c, &input, 997);
    assert_eq!(decode_only, 0);
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
fn fragments_that_start_mid_gop_replay_the_gop() {
    let input = fixture("midgop.mp4");
    let mut c = Converter::new(false);
    let (out, decode_only) = convert(&mut c, &input, input.len());
    assert!(decode_only > 0, "no fragment started mid-GOP");
    if has_ffmpeg() {
        let src = write_temp("midgop-in.mp4", &input);
        let dst = write_temp("midgop-out.mp4", &out);
        assert_eq!(packet_times(&src), packet_times(&dst));
        // Frames whose B-frames came in the next fragment waited for them,
        // so decode order never goes back.
        let out = Command::new("ffprobe")
            .args(["-v", "error", "-show_entries", "packet=dts,flags", "-of", "csv=p=0"])
            .arg(&dst)
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
}

#[test]
fn separate_video_segments() {
    let mut input = fixture("video-init.mp4");
    let mut c = Converter::new(false);
    let (mut out, _) = convert(&mut c, &input, input.len());
    assert!(!out.is_empty(), "the init converts before any media");
    for i in 0..3 {
        let seg = fixture(&format!("video-{i}.m4s"));
        let (mut more, _) = convert(&mut c, &seg, seg.len());
        assert!(!more.is_empty());
        out.append(&mut more);
        input.extend_from_slice(&seg);
    }
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
    let (out, _) = convert(&mut c, &input, 1000);
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
    let (out, _) = convert(&mut c, &input, 4096);
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
    let (out, _) = convert(&mut c, &input, input.len());
    assert_eq!(c.mime, "video/mp4; codecs=\"vp09.00.41.08,flac\"");
    // Keyframes come every second of the two, so no cut is 2 s long.
    assert_eq!(out.windows(4).filter(|w| w == b"moof").count(), 1);
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
fn reset_drops_partial_input_but_keeps_the_init() {
    let init = fixture("video-init.mp4");
    let seg = fixture("video-1.m4s");
    let mut c = Converter::new(false);
    convert(&mut c, &init, init.len());
    let (out, _) = convert(&mut c, &seg[..seg.len() / 2], seg.len());
    assert!(out.is_empty());
    c.reset();
    let (out, _) = convert(&mut c, &seg, seg.len());
    assert!(!out.is_empty());
    assert_eq!(c.init_generation, 1);
}

#[test]
fn garbage_fails_without_wedging() {
    let mut c = Converter::new(false);
    c.push(&[0, 0, 0, 3, 1, 2, 3, 4, 5]);
    assert!(c.poll().is_err());
    let init = fixture("video-init.mp4");
    let (out, _) = convert(&mut c, &init, init.len());
    assert!(!out.is_empty());
    let mut c = Converter::new(false);
    c.push(&fixture("video-0.m4s"));
    assert!(c.poll().is_err(), "media before init");
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
        let (mut out, _) = convert(&mut c, &input, input.len());
        for i in 0.. {
            let Some(seg) = read(&format!("{prefix}{i}.m4s")) else { break };
            let (mut more, _) = convert(&mut c, &seg, seg.len());
            out.append(&mut more);
            input.extend(seg);
        }
        let src = write_temp(&format!("local-{prefix}-in.mp4"), &input);
        let dst = write_temp(&format!("local-{prefix}-out.mp4"), &out);
        // X's video uses negative composition offsets, which ffmpeg reads
        // shifted by the largest one; compare the timelines' shapes.
        assert_eq!(relative(packet_times(&src)), relative(packet_times(&dst)), "{init}");
    }
    for name in ["v.mp4", "gif.mp4"] {
        let Some(input) = read(name) else { continue };
        let mut c = Converter::new(true);
        let (out, _) = convert(&mut c, &input, 65536);
        let src = write_temp(&format!("local-{name}"), &input);
        let dst = write_temp(&format!("local-out-{name}"), &out);
        assert_eq!(relative(packet_times(&src)), relative(packet_times(&dst)), "{name}");
    }
}
