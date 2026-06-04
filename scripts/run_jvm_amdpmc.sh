#!/usr/bin/env bash
# run_jvm_amdpmc.sh — AMD-native PMC verification of the JVM THP win.
# Captures the AMD Zen5/Turin official TLB events (mapped from amd-perf-toolkit
# AMD_OFFICIAL_PMC_EVENTS.md) so the documented page-walk reduction is verified
# directly from hardware counters, not from generic perf aliases.
#
#   l1_dtlb_misses          = Event[0x43FF45]  -> raw r43FF45  (ls_l1_d_tlb_miss.all)
#   l2_dtlb_misses / walks  = Event[0x43F045]  -> raw r43F045  (ls_l1_d_tlb_miss.all_l2_miss = page-table walks)
# Plus the page-size split of completed walks:
#   tlb_reload_4k_l2_miss / tlb_reload_2m_l2_miss  -> walk landed on a 4K vs 2M page.
#
# page_walk_rate (toolkit metric) = r43F045 / instructions
# tlb_miss_rate  (toolkit metric) = r43FF45 / instructions
# Must run as root (writes /sys THP knobs).
set -u
GIB=${1:-15}
STEPS=${2:-300000000}
HEAP=${3:-20}
OUT=${4:-/tmp/thp_results}
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DIR=${DIR:-$REPO}
mkdir -p "$OUT"

# AMD-native event list. Symbolic names resolve on the m8a guest; raw codes are
# the toolkit's official equivalents and used as a fallback if names fail.
EVENTS_SYM="instructions,cycles,ls_l1_d_tlb_miss.all,ls_l1_d_tlb_miss.all_l2_miss,ls_l1_d_tlb_miss.tlb_reload_4k_l2_miss,ls_l1_d_tlb_miss.tlb_reload_2m_l2_miss"
EVENTS_RAW="instructions,cycles,r43FF45,r43F045"

thp_enabled="/sys/kernel/mm/transparent_hugepage/enabled"
thp_defrag="/sys/kernel/mm/transparent_hugepage/defrag"

run_mode() {
  local mode=$1 jvmflag=$2 events=$3 tag=$4
  echo "$mode" > "$thp_enabled"
  echo "$mode" > "$thp_defrag"
  sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  ( perf stat -x, -o "$OUT/amdpmc_${tag}_${mode}.csv" -e "$events" \
      java -Xms${HEAP}g -Xmx${HEAP}g -XX:+AlwaysPreTouch $jvmflag \
      -cp "$DIR" LatBench "$GIB" "$STEPS" > "$OUT/amdres_${tag}_${mode}.json" 2> "$OUT/amdrun_${tag}_${mode}.log" )
  echo "thp_mode=$mode jvmflag=$jvmflag events=$events" >> "$OUT/amdrun_${tag}_${mode}.log"
}

echo "### AMD-PMC JVM THP test: GIB=$GIB STEPS=$STEPS HEAP=${HEAP}g ###"

# Probe whether symbolic AMD events are usable on this guest.
if perf stat -e "$EVENTS_SYM" true 2>/dev/null; then
  EVTAG=sym; USE="$EVENTS_SYM"
  echo "Using SYMBOLIC AMD events."
else
  EVTAG=raw; USE="$EVENTS_RAW"
  echo "Symbolic AMD events unavailable; using RAW codes r43FF45/r43F045."
fi

run_mode never  "-XX:-UseTransparentHugePages" "$USE" "$EVTAG"
run_mode always "-XX:+UseTransparentHugePages" "$USE" "$EVTAG"

echo "===== AMD-PMC RESULTS (evtag=$EVTAG) ====="
for m in never always; do
  echo "--- THP=$m ---"
  cat "$OUT/amdres_${EVTAG}_${m}.json" 2>/dev/null
  echo "perf (AMD-native):"
  grep -vE '^#|^$' "$OUT/amdpmc_${EVTAG}_${m}.csv" 2>/dev/null
  echo
done
echo "EVTAG=$EVTAG"
