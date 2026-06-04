#!/usr/bin/env bash
# run_micro_amdpmc.sh — AMD-native PMC verification of the C pointer-chase win.
# Same official Zen5/Turin TLB events used for the JVM pass, so both workloads
# are verified with an identical, consistent counter set.
#   ls_l1_d_tlb_miss.all          = r43FF45  (L1 DTLB misses)
#   ls_l1_d_tlb_miss.all_l2_miss  = r43F045  (page-table walks)
#   tlb_reload_4k_l2_miss / tlb_reload_2m_l2_miss = walk page-size split
# Must run as root (writes /sys THP knobs).
set -u
GIB=${1:-8}
STEPS=${2:-300000000}
OUT=${3:-/tmp/thp_results}
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BIN=${BIN:-$REPO/microbench}
mkdir -p "$OUT"

EVENTS_SYM="instructions,cycles,ls_l1_d_tlb_miss.all,ls_l1_d_tlb_miss.all_l2_miss,ls_l1_d_tlb_miss.tlb_reload_4k_l2_miss,ls_l1_d_tlb_miss.tlb_reload_2m_l2_miss"
EVENTS_RAW="instructions,cycles,r43FF45,r43F045"

thp_enabled="/sys/kernel/mm/transparent_hugepage/enabled"
thp_defrag="/sys/kernel/mm/transparent_hugepage/defrag"

run_mode() {
  local mode=$1 events=$2 tag=$3
  echo "$mode" > "$thp_enabled"
  echo "$mode" > "$thp_defrag"
  sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  ( perf stat -x, -o "$OUT/microamd_${tag}_${mode}.csv" -e "$events" \
        "$BIN" "$GIB" "$STEPS" > "$OUT/microamdres_${tag}_${mode}.json" 2> "$OUT/microamdrun_${tag}_${mode}.log" ) &
  local pj=$!
  local peak=0
  while kill -0 "$pj" 2>/dev/null; do
    v=$(awk '/AnonHugePages/{print $2}' /proc/meminfo)
    [ "${v:-0}" -gt "$peak" ] && peak=$v
    sleep 0.5
  done
  wait "$pj"
  echo "peak_AnonHugePages_kB=$peak" >> "$OUT/microamdrun_${tag}_${mode}.log"
  echo "thp_mode=$mode events=$events" >> "$OUT/microamdrun_${tag}_${mode}.log"
}

echo "### AMD-PMC microbench THP test: GIB=$GIB STEPS=$STEPS ###"
if perf stat -e "$EVENTS_SYM" true 2>/dev/null; then
  EVTAG=sym; USE="$EVENTS_SYM"; echo "Using SYMBOLIC AMD events."
else
  EVTAG=raw; USE="$EVENTS_RAW"; echo "Symbolic AMD events unavailable; using RAW codes."
fi

run_mode never  "$USE" "$EVTAG"
run_mode always "$USE" "$EVTAG"

echo "===== AMD-PMC MICRO RESULTS (evtag=$EVTAG) ====="
for m in never always; do
  echo "--- THP=$m ---"
  cat "$OUT/microamdres_${EVTAG}_${m}.json" 2>/dev/null
  grep -E "peak_AnonHugePages_kB|checksum" "$OUT/microamdrun_${EVTAG}_${m}.log" 2>/dev/null
  echo "perf (AMD-native):"; grep -vE '^#|^$' "$OUT/microamd_${EVTAG}_${m}.csv" 2>/dev/null
  echo
done
echo "EVTAG=$EVTAG"
