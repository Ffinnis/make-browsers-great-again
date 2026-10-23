#!/usr/bin/env bash
# Regenerates the test media. Synthetic sources only: no real site's video
# belongs in the repository.
set -euo pipefail
cd "$(dirname "$0")"

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
src=(-f lavfi -i testsrc2=size=320x180:rate=30 -f lavfi -i sine=frequency=440:sample_rate=44100)
x264=(-c:v libx264 -profile:v high -preset veryfast -b:v 150k -bf 2 -g 30 -keyint_min 30 -sc_threshold 0 -pix_fmt yuv420p)
hls=(-f hls -hls_time 1 -hls_segment_type fmp4)

# Muxed CMAF: H.264 High with B-frames and AAC-LC in one file, a fragment per second.
ff "${src[@]}" -t 2 "${x264[@]}" -c:a aac -b:a 64k -ac 2 \
  -movflags frag_keyframe+empty_moov+default_base_moof muxed.mp4

# Half-second fragments over one-second GOPs, so every other fragment
# starts mid-GOP, like low-latency streams.
ff "${src[@]}" -t 2 -map 0:v "${x264[@]}" -movflags empty_moov+default_base_moof -frag_duration 500000 midgop.mp4

# Separate video and audio CMAF, the way X and most HLS players deliver it.
ff "${src[@]}" -t 3 -map 0:v "${x264[@]}" "${hls[@]}" \
  -hls_fmp4_init_filename video-init.mp4 -hls_segment_filename 'video-%d.m4s' video.m3u8
ff "${src[@]}" -t 3 -map 1:a -c:a aac -b:a 64k -ac 2 "${hls[@]}" \
  -hls_fmp4_init_filename aac-init.mp4 -hls_segment_filename 'aac-%d.m4s' aac.m3u8
# HE-AAC through AudioToolbox, so this part needs a Mac.
ff "${src[@]}" -t 3 -map 1:a -c:a aac_at -profile:a 4 -b:a 32k -ac 2 "${hls[@]}" \
  -hls_fmp4_init_filename heaac-init.mp4 -hls_segment_filename 'heaac-%d.m4s' heaac.m3u8
rm -f ./*.m3u8

# avc3, with SPS and PPS before every keyframe, whose size grows from
# 320x180 to 480x270 at 1 s: the SPS changes it, not an init.
for size in 320x180 480x270; do
  ff -f lavfi -i "testsrc2=size=$size:rate=30" -t 1 "${x264[@]}" -x264-params repeat-headers=1 "avc3-$size.mp4"
done
printf "file '%s'\n" avc3-320x180.mp4 avc3-480x270.mp4 >avc3.txt
ff -f concat -i avc3.txt -c copy -tag:v avc3 -movflags empty_moov+default_base_moof+frag_keyframe avc3.mp4
rm -f avc3-*.mp4 avc3.txt

# Progressive files: a muted loop like X's GIFs with moov last, and one with
# audio and moov first.
ff "${src[@]}" -t 2 -map 0:v -c:v libx264 -profile:v main -preset veryfast -b:v 100k -bf 2 -g 15 gif.mp4
ff "${src[@]}" -t 2 "${x264[@]}" -c:a aac -b:a 64k -ac 2 -movflags +faststart progressive.mp4

# A progressive file with one keyframe in six seconds, like screen
# recordings: fragments can't wait for keyframes.
ff "${src[@]}" -t 6 -c:v libx264 -profile:v high -preset veryfast -b:v 100k -bf 2 -g 1000 -keyint_min 1000 \
  -sc_threshold 0 -pix_fmt yuv420p -c:a aac -b:a 48k -ac 2 -movflags +faststart sparse.mp4
