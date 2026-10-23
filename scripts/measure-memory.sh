#!/usr/bin/env bash
set -euo pipefail

total=0
printf "%10s  %s\n" "Footprint" "Process"
for pid in $(pgrep -f 'MBGA.app/Contents/' || true); do
  [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == *MBGA* ]] || continue
  cmd="$(ps -o command= -p "$pid" || true)"
  [[ -z "$cmd" ]] && continue
  kind="$(grep -oE -- '--type=[a-z-]+' <<<"$cmd" | cut -d= -f2 || true)"
  sub="$(grep -oE -- '--utility-sub-type=[A-Za-z.]+' <<<"$cmd" | cut -d= -f2 || true)"
  line="$(footprint -p "$pid" 2>/dev/null | grep -m1 'Footprint:' || true)"
  [[ -z "$line" ]] && continue
  value="$(sed -E 's/.*Footprint: ([0-9.]+) (KB|MB|GB).*/\1 \2/' <<<"$line")"
  mb="$(awk '{ if ($2=="KB") print $1/1024; else if ($2=="GB") print $1*1024; else print $1 }' <<<"$value")"
  total="$(awk -v a="$total" -v b="$mb" 'BEGIN { print a + b }')"
  printf "%7.1f MB  %s %s\n" "$mb" "${kind:-browser}" "$sub"
done
printf "%7.1f MB  total\n" "$total"
