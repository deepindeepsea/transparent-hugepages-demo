#!/usr/bin/env bash
# run_redis.sh — Redis as an in-memory cache (NO persistence) under THP off vs on.
# Loads a large keyspace, then drives random GET/SET load with memtier_benchmark.
# Persistence is disabled on purpose so we isolate the memory-access effect of THP
# and avoid the well-known THP+fork(copy-on-write) latency penalty during bgsave.
# Must run as root.
set -u
KEYS=${1:-5000000}        # number of keys to preload
DATASIZE=${2:-512}        # value size in bytes
SECONDS_RUN=${3:-30}      # memtier test duration per mode
THREADS=${4:-4}
CLIENTS=${5:-25}
OUT=${6:-/tmp/thp_results}
mkdir -p "$OUT"

thp_enabled="/sys/kernel/mm/transparent_hugepage/enabled"
thp_defrag="/sys/kernel/mm/transparent_hugepage/defrag"
PORT=6399

start_redis() {
  redis-server --port $PORT --save "" --appendonly no \
    --maxmemory 0 --daemonize yes --protected-mode no \
    --logfile "$OUT/redis_$1.log" --dir /tmp
  for i in $(seq 1 30); do
    redis-cli -p $PORT ping 2>/dev/null | grep -q PONG && break
    sleep 0.5
  done
}
stop_redis() { redis-cli -p $PORT shutdown nosave 2>/dev/null || true; sleep 1; }

run_mode() {
  local mode=$1
  echo "$mode" > "$thp_enabled"
  echo "$mode" > "$thp_defrag"
  sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  stop_redis
  start_redis "$mode"

  # Preload keyspace (writes), so the dataset is large & resident in huge/base pages.
  memtier_benchmark -p $PORT --hide-histogram \
     --ratio=1:0 -n allkeys --key-pattern=P:P \
     --key-minimum=1 --key-maximum=$KEYS -d $DATASIZE \
     -t $THREADS -c $CLIENTS > "$OUT/redis_load_${mode}.txt" 2>&1

  redis-cli -p $PORT info memory | grep -E "used_memory_human|used_memory:" > "$OUT/redis_mem_${mode}.txt"
  peak=$(awk '/AnonHugePages/{print $2}' /proc/meminfo)
  echo "AnonHugePages_kB_after_load=$peak" >> "$OUT/redis_mem_${mode}.txt"

  # Steady-state random GET-heavy load (90% GET / 10% SET) for SECONDS_RUN.
  memtier_benchmark -p $PORT --hide-histogram \
     --ratio=1:9 --key-pattern=R:R \
     --key-minimum=1 --key-maximum=$KEYS -d $DATASIZE \
     -t $THREADS -c $CLIENTS --test-time=$SECONDS_RUN \
     --json-out-file="$OUT/redis_run_${mode}.json" > "$OUT/redis_run_${mode}.txt" 2>&1

  stop_redis
}

echo "### Redis THP test: KEYS=$KEYS DATASIZE=$DATASIZE DUR=${SECONDS_RUN}s ###"
run_mode never
run_mode always

echo "===== REDIS RESULTS ====="
for m in never always; do
  echo "--- THP=$m ---"
  cat "$OUT/redis_mem_${m}.txt"
  echo "memtier summary:"
  grep -E "Totals|Ops/sec|Latency|Percentile|GET|SET" "$OUT/redis_run_${m}.txt" | grep -iE "totals|ops/sec" | head
  echo
done
