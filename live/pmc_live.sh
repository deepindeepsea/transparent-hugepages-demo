#!/usr/bin/env bash
# pmc_live.sh - live PMC readout for the THP demo bottom pane.
# Samples the SAME counters we capture in the A/B, system-wide, every 1s,
# so the numbers reflect whatever the top pane is currently doing.
set -u
EV="instructions,ls_l1_d_tlb_miss.all_l2_miss,dTLB-loads,dTLB-load-misses"
fmt(){ awk 'BEGIN{n="'"$1"'"} {x=n}; END{ if(n=="" ){print "n/a"; exit}
  # group thousands
  s=n; out=""; while(length(s)>3){out=substr(s,length(s)-2)","out; s=substr(s,1,length(s)-3)} print s out }' </dev/null; }
while true; do
  THP=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled)
  AHP=$(awk '/AnonHugePages/{print $2}' /proc/meminfo)
  OUT=$(perf stat -a -e "$EV" -- sleep 1 2>&1)
  walks=$(echo "$OUT" | awk '/ls_l1_d_tlb_miss.all_l2_miss/{gsub(/,/,"",$1);print $1}')
  ins=$(echo  "$OUT" | awk '/instructions/{gsub(/,/,"",$1);print $1}')
  dtlbm=$(echo "$OUT"| awk '/dTLB-load-misses/{gsub(/,/,"",$1);print $1}')
  dtlb=$(echo "$OUT" | awk '/dTLB-loads/{gsub(/,/,"",$1);print $1}')
  clear
  echo  "================ LIVE PMC MONITOR (1s system-wide sample) ================"
  printf "  THP mode now : [ %s ]      AnonHugePages: %s kB\n" "$THP" "$AHP"
  echo  "-------------------------------------------------------------------------"
  printf "  page-table walks / s   (ls_l1_d_tlb_miss.all_l2_miss): %s\n" "${walks:-n/a}"
  printf "  dTLB-load-misses / s                                 : %s\n" "${dtlbm:-n/a}"
  printf "  dTLB-loads / s                                       : %s\n" "${dtlb:-n/a}"
  printf "  instructions / s                                     : %s\n" "${ins:-n/a}"
  if [ -n "${walks:-}" ] && [ -n "${ins:-}" ] && [ "${ins:-0}" -gt 0 ] 2>/dev/null; then
    awk -v w="$walks" -v i="$ins" 'BEGIN{printf "  >> walks per 1,000 instructions                      : %.2f\n", w/i*1000}'
  fi
  echo  "-------------------------------------------------------------------------"
  echo  "  THP=never  -> walks in the BILLIONS   |   THP=always -> walks in the MILLIONS"
  echo  "  (top pane flips the mode every pass; watch this number collapse on [always])"
done
