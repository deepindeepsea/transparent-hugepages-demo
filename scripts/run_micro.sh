#!/usr/bin/env bash
# run_micro.sh — run the pointer-chasing microbench under THP=never vs THP=always
# Captures perf counters (TLB + page-walk pressure) and peak AnonHugePages.
# Must run as root (writes /sys THP knobs, drop_caches, perf).
set -u
GIB=${1:-8}
STEPS=${2:-300000000}
OUT=${3:-/tmp/thp_results}
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BIN=${BIN:-$REPO/microbench}
mkdir -p "$OUT"

EVENTS="task-clock,cycles,instructions,dTLB-loads,dTLB-load-misses"

thp_enabled="/sys/kernel/mm/transparent_hugepage/enabled"
thp_defrag="/sys/kernel/mm/transparent_hugepage/defrag"

run_mode() {
  local mode=$1
  echo "$mode" > "$thp_enabled"
  echo "$mode" > "$thp_defrag"
  sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  # background sampler for peak system AnonHugePages while the bench runs
  ( perf stat -x, -o "$OUT/perf_${mode}.csv" -e "$EVENTS" \
        "$BIN" "$GIB" "$STEPS" > "$OUT/res_${mode}.json" 2> "$OUT/run_${mode}.log" ) &
  local pj=$!
  local peak=0
  while kill -0 "$pj" 2>/dev/null; do
    local v
    v=$(awk '/AnonHugePages/{print $2}' /proc/meminfo)
    [ "${v:-0}" -gt "$peak" ] && peak=$v
    sleep 0.5
  done
  wait "$pj"
  echo "peak_AnonHugePages_kB=$peak" >> "$OUT/run_${mode}.log"
  echo "thp_mode=$mode" >> "$OUT/run_${mode}.log"
}

echo "### THP microbench: GIB=$GIB STEPS=$STEPS ###"
run_mode never
run_mode always

echo "===== RESULTS ====="
for m in never always; do
  echo "--- THP=$m ---"
  cat "$OUT/res_${m}.json"
  grep -E "peak_AnonHugePages_kB|checksum" "$OUT/run_${m}.log"
  echo "perf:"; cat "$OUT/perf_${m}.csv" | grep -vE "^#|^$"
  echo
done
