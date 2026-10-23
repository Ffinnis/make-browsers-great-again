"""Works out the timeline each harness case should buffer, from the input.

Fragmented input is read here the way the engine reads it (signed
composition offsets, a single edit list entry shifting the track);
progressive files go through ffprobe. Each SourceBuffer's expected range is
the intersection of its tracks', as the engine reports it, except that a
muxed segment's tracks all start where its earliest one does: the engine
starts a coded frame group there and covers the small gap.

    python3 media/harness/expect.py [samples-dir] [output-dir]
"""

import json
import pathlib
import struct
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
FIXTURES = HERE.parent / "tests" / "fixtures"
SAMPLES = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/video-delivery-research")
OUT = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "/tmp/mbga-media-harness")


def boxes(data, start=0, end=None):
    pos, end = start, len(data) if end is None else end
    while pos + 8 <= end:
        size, kind = struct.unpack(">I4s", data[pos : pos + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[pos + 8 : pos + 16])[0]
            header = 16
        yield kind, pos + header, pos + size
        pos += size


def find(data, start, end, path):
    for kind, body, stop in boxes(data, start, end):
        if kind == path[0]:
            return (body, stop) if len(path) == 1 else find(data, body, stop, path[1:])
    return None


def u32(data, at):
    return struct.unpack(">I", data[at : at + 4])[0]


def full_box_field(data, body, v0_offset):
    """A field after a full box's times, which are twice as long in version 1."""
    at = body + (v0_offset + 8 if data[body] == 1 else v0_offset)
    return u32(data, at)


def edit_shift(data, trak):
    """media_time of a single-entry edit list, which the engine subtracts."""
    elst = find(data, *trak, [b"edts", b"elst"])
    if not elst or u32(data, elst[0] + 4) != 1:
        return 0
    wide = data[elst[0]] == 1
    at = elst[0] + 8 + (8 if wide else 4)
    return max(0, struct.unpack(">q" if wide else ">i", data[at : at + (8 if wide else 4)])[0])


def read_moov(data):
    tracks, durations = {}, {}
    moov = find(data, 0, None, [b"moov"])
    for kind, body, stop in boxes(data, *moov):
        if kind == b"trak":
            tid = full_box_field(data, find(data, body, stop, [b"tkhd"])[0], 12)
            scale = full_box_field(data, find(data, body, stop, [b"mdia", b"mdhd"])[0], 12)
            tracks[tid] = {"scale": scale, "shift": edit_shift(data, (body, stop)), "frames": [], "next": 0}
        if kind == b"mvex":
            for k, b, _ in boxes(data, body, stop):
                if k == b"trex":
                    durations[u32(data, b + 4)] = u32(data, b + 12)
    return tracks, durations


def read_trun(data, rb, dts, duration):
    """(dts, pts, duration) of each sample in a trun."""
    signed = data[rb] == 1
    flags = u32(data, rb) & 0xFFFFFF
    at = rb + 8 + (4 if flags & 1 else 0) + (4 if flags & 4 else 0)
    samples = []
    for _ in range(u32(data, rb + 4)):
        d, cto = duration, 0
        for bit in (0x100, 0x200, 0x400, 0x800):
            if flags & bit:
                value = struct.unpack(">i" if signed and bit == 0x800 else ">I", data[at : at + 4])[0]
                d = value if bit == 0x100 else d
                cto = value if bit == 0x800 else cto
                at += 4
        samples.append((dts, dts + cto, d))
        dts += d
    return samples


def read_traf(data, tracks, durations, traf):
    parts = {k: b for k, b, _ in boxes(data, *traf)}
    tfhd = parts[b"tfhd"]
    flags, tid = u32(data, tfhd) & 0xFFFFFF, u32(data, tfhd + 4)
    duration = durations.get(tid, 0)
    if flags & 8:
        duration = u32(data, tfhd + 8 + (8 if flags & 1 else 0) + (4 if flags & 2 else 0))
    track = tracks[tid]
    dts = track["next"]
    if b"tfdt" in parts:
        b = parts[b"tfdt"]
        dts = struct.unpack(">Q", data[b + 4 : b + 12])[0] if data[b] == 1 else u32(data, b + 4)
    for kind, body, _ in boxes(data, *traf):
        if kind == b"trun":
            samples = read_trun(data, body, dts, duration)
            track["frames"] += samples
            if samples:
                dts = samples[-1][0] + samples[-1][2]
    track["next"] = dts


def fragmented(data):
    tracks, durations = read_moov(data)
    for kind, body, stop in boxes(data):
        if kind == b"moof":
            for k, tb, ts in boxes(data, body, stop):
                if k == b"traf":
                    read_traf(data, tracks, durations, (tb, ts))
    ranges = []
    for t in tracks.values():
        if t["frames"]:
            starts = [(pts - t["shift"]) / t["scale"] for _, pts, _ in t["frames"]]
            ends = [(pts - t["shift"] + d) / t["scale"] for _, pts, d in t["frames"]]
            ranges.append((min(starts), max(ends)))
    return ranges


def progressive(path):
    out = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "packet=stream_index,pts_time,duration_time",
            "-of",
            "csv=p=0",
            path,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    ranges = {}
    for line in out.splitlines():
        index, pts, dur = line.split(",")[:3]
        start, end = float(pts), float(pts) + float(dur)
        lo, hi = ranges.get(index, (start, end))
        ranges[index] = (min(lo, start), max(hi, end))
    return list(ranges.values())


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    expected = {}
    for case in json.loads((HERE / "cases.json").read_text()):
        # Cases that change their input (aborts, damage) say what to expect
        # themselves, if anything.
        if case.get("noExpect") or case.get("errorsOnly"):
            continue
        result = []
        for sb in case["sbs"]:
            data = b"".join(
                ((FIXTURES if f.startswith("fixtures/") else SAMPLES) / f.split("/", 1)[1]).read_bytes()
                for name in sb["files"]
                for f in name.split("+")
            )
            moov = find(data, 0, None, [b"moov"])
            if sb["mime"] != "progressive" or find(data, *moov, [b"mvex"]):
                ranges = fragmented(data)
            else:
                path = OUT / f"{case['name']}-input.mp4"
                path.write_bytes(data)
                ranges = progressive(path)
            # Nothing buffers before 0: the engine trims it off.
            result.append([max(0.0, min(r[0] for r in ranges)), min(r[1] for r in ranges)])
        expected[case["name"]] = result
    (OUT / "expected.json").write_text(json.dumps(expected, indent=1))
    print(json.dumps(expected))


if __name__ == "__main__":
    main()
