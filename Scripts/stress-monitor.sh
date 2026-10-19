#!/usr/bin/env bash
# Samples a running Zapdrop's memory, CPU, threads and open files into a CSV, for long real-phone stress sessions.
#   Scripts/stress-monitor.sh [interval-seconds] [output.csv]
# Waits for Zapdrop to start, keeps sampling across restarts (the pid column shows them), stops with Ctrl-C.
# Steady growth in footprint_mb, threads or open_files over hours is the thing to look for (docs/TESTING.md).
set -euo pipefail

INTERVAL="${1:-5}"
OUT="${2:-zapdrop-stress-$(date +%Y%m%d-%H%M%S).csv}"

# "Footprint: 42 MB" → 42 (KB and GB converted to MB).
footprint_mb() {
  footprint -p "$1" 2>/dev/null | awk '/Footprint:/ {
    for (i = 1; i <= NF; i++) if ($i == "Footprint:") { v = $(i + 1); u = $(i + 2) }
    if (u == "KB") v /= 1024; else if (u == "GB") v *= 1024
    printf "%.1f", v; exit }'
}

echo "time,pid,footprint_mb,rss_mb,cpu_percent,threads,open_files" > "$OUT"
echo "Sampling Zapdrop every ${INTERVAL}s into $OUT (Ctrl-C to stop)"
while true; do
  pid=$(pgrep -x Zapdrop | head -n 1 || true)
  if [[ -n "$pid" ]]; then
    read -r rss_kb cpu < <(ps -o rss=,%cpu= -p "$pid" || echo "0 0")
    threads=$(( $(ps -M -p "$pid" 2>/dev/null | wc -l) - 1 ))
    files=$(lsof -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    printf '%s,%s,%s,%.1f,%s,%s,%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$pid" "$(footprint_mb "$pid")" \
      "$(echo "$rss_kb / 1024" | bc -l)" "$cpu" "$threads" "$files" >> "$OUT"
  fi
  sleep "$INTERVAL"
done
