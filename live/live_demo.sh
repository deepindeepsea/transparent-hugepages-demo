#!/usr/bin/env bash
# live_demo.sh — continuous THP demo for the tmux/ttyd live view.
# Loops the C pointer-chase under THP=never then THP=always, printing the
# ns/access + page-walk delta each cycle so a viewer always sees motion.
set -u
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BIN=${BIN:-$REPO/microbench}
GIB=${1:-8}
STEPS=${2:-120000000}    # smaller step count so each pass is ~20-25s
thp_enabled="/sys/kernel/mm/transparent_hugepage/enabled"
thp_defrag="/sys/kernel/mm/transparent_hugepage/defrag"
EV="instructions,ls_l1_d_tlb_miss.all_l2_miss"

run() {
  local mode=$1
  echo "$mode" > "$thp_enabled" 2>/dev/null
  echo "$mode" > "$thp_defrag"  2>/dev/null
  sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  echo "================================================================"
  echo "  THP = $mode   ($(date '+%H:%M:%S'))   GiB=$GIB STEPS=$STEPS"
  echo "----------------------------------------------------------------"
  perf stat -e "$EV" "$BIN" "$GIB" "$STEPS" 2>/tmp/thp_live_perf.txt
  awk '/ls_l1_d_tlb_miss.all_l2_miss/{w=$1} /instructions/{i=$1}
       END{gsub(/,/,"",w);gsub(/,/,"",i); if(i>0) printf "  >> page-table walks: %s   walks/1k-instr: %.2f\n", w, w/i*1000}' /tmp/thp_live_perf.txt
  echo "  AnonHugePages: $(awk '/AnonHugePages/{print $2" kB"}' /proc/meminfo)"
  echo
}

echo "### LIVE THP DEMO — Ctrl-C safe; loops forever ###"
while true; do
  run never
  run always
  echo "----- cycle complete; restarting in 3s -----"; sleep 3
done
