#!/usr/bin/env bash
# run_jvm.sh — large-heap JVM pointer-chase under THP off vs on.
# Mirrors the production customer scenario (large JVM heap, random memory access).
# THP off  : OS thp=never  + JVM -XX:-UseTransparentHugePages
# THP on   : OS thp=always + JVM -XX:+UseTransparentHugePages (+ AlwaysPreTouch)
# Captures perf TLB/page-walk counters + peak AnonHugePages. Must run as root.
set -u
GIB=${1:-15}              # working-set GiB for the on-heap long[]
STEPS=${2:-300000000}     # dependent loads per run
HEAP=${3:-20}             # -Xms/-Xmx in GiB (AlwaysPreTouch faults it all up front)
OUT=${4:-/tmp/thp_results}
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DIR=${DIR:-$REPO}
mkdir -p "$OUT"

EVENTS="task-clock,cycles,instructions,dTLB-loads,dTLB-load-misses"
thp_enabled="/sys/kernel/mm/transparent_hugepage/enabled"
thp_defrag="/sys/kernel/mm/transparent_hugepage/defrag"

run_mode() {
  local mode=$1 jvmflag=$2
  echo "$mode" > "$thp_enabled"
  echo "$mode" > "$thp_defrag"
  sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  ( perf stat -x, -o "$OUT/jperf_${mode}.csv" -e "$EVENTS" \
      java -Xms${HEAP}g -Xmx${HEAP}g -XX:+AlwaysPreTouch $jvmflag \
      -cp "$DIR" LatBench "$GIB" "$STEPS" > "$OUT/jres_${mode}.json" 2> "$OUT/jrun_${mode}.log" ) &
  local pj=$!
  local peak=0
  while kill -0 "$pj" 2>/dev/null; do
    v=$(awk '/AnonHugePages/{print $2}' /proc/meminfo)
    [ "${v:-0}" -gt "$peak" ] && peak=$v
    sleep 0.5
  done
  wait "$pj"
  echo "peak_AnonHugePages_kB=$peak" >> "$OUT/jrun_${mode}.log"
  echo "thp_mode=$mode jvmflag=$jvmflag" >> "$OUT/jrun_${mode}.log"
}

echo "### JVM THP test: GIB=$GIB STEPS=$STEPS HEAP=${HEAP}g ###"
run_mode never  "-XX:-UseTransparentHugePages"
run_mode always "-XX:+UseTransparentHugePages"

echo "===== JVM RESULTS ====="
for m in never always; do
  echo "--- THP=$m ---"
  cat "$OUT/jres_${m}.json"
  grep -E "peak_AnonHugePages_kB|thp_mode" "$OUT/jrun_${m}.log"
  echo "perf:"; grep -vE '^#|^$' "$OUT/jperf_${m}.csv"
  echo
done
