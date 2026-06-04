# Transparent Huge Pages (THP) Demo & Benchmarks

A self-contained benchmark suite that **demonstrates, with hardware performance
counters, the value of Transparent Huge Pages (THP)** on modern AMD EPYC servers.
It runs the same memory-latency-bound workload twice — once with THP disabled
(4 KB pages) and once with THP enabled (2 MB pages) — and measures the
difference in **page-table walks, dTLB misses, and wall-clock time** straight
from the CPU's PMU.

The headline effect this suite was built to show: on a large (multi-GiB),
pointer-chasing working set, enabling THP collapses page-table-walk traffic by
**~200x** and meaningfully shortens runtime, because each 2 MB page covers 512x
more address space per TLB entry than a 4 KB page.

> **Why this matters for cost / TCO.** Latency-bound services (in-memory
> databases, JVM fleets, inference servers, KV caches) spend a surprising
> fraction of their cycles servicing dTLB misses and page-table walks. Reclaiming
> those cycles with THP means the same work finishes on fewer cores / less
> wall-clock time — fewer instances for the same throughput, i.e. direct
> infrastructure savings. THP is a kernel/OS knob with **no application code
> change**, which makes it one of the cheapest performance levers available in a
> production fleet.

---

## What's in here

\`\`\`
src/
  LatBench.java          Java pointer-chasing latency benchmark (the headline JVM demo)
  microbench.c           C equivalent — mmap + madvise(MADV_HUGEPAGE), no JVM noise
scripts/
  run_jvm.sh             LatBench: THP never vs always, generic perf events
  run_jvm_amdpmc.sh      LatBench: THP never vs always, AMD-native PMC events (+ raw fallback)
  run_micro.sh           microbench: THP never vs always, generic perf events
  run_micro_amdpmc.sh    microbench: THP never vs always, AMD-native PMC events (+ raw fallback)
  run_redis.sh           Redis (memtier-driven) THP off vs on — a realistic service example
live/
  live_demo.sh           Continuous A/B loop for a live tmux dashboard (top pane)
  pmc_live.sh            System-wide live PMC monitor (bottom pane)
setup.sh                 One-shot dependency installer (apt/dnf) + build
Makefile                 build / run targets
\`\`\`

---

## How the benchmark works

Both \`LatBench.java\` and \`microbench.c\` allocate a large array (default
8-15 GiB), fill it as an identity permutation, then apply **Sattolo's
algorithm** to turn it into a single giant cycle. The benchmark then "chases"
that cycle: each load's address depends on the value just read
(\`i = a[i]\`). This has two deliberate properties:

1. **It defeats the hardware prefetcher** — the next address is unknowable until
   the current load retires, so every access is a fresh, random memory reference.
2. **It thrashes the dTLB** — because the working set is many GiB and the access
   pattern is random, almost every access touches a different page, forcing a TLB
   miss and (with 4 KB pages) a multi-level page-table walk.

This is the worst case for small pages and the best case for huge pages, which is
exactly what makes the THP effect so visible. It's a stress test, not a claim
that every workload sees 200x — production gains are smaller but real.

---

## Quick start

### 1. Install dependencies and build

\`\`\`bash
./setup.sh          # installs OpenJDK, gcc, linux perf tools; builds both benches
# or, manually:
make
\`\`\`

\`setup.sh\` installs (Debian/Ubuntu and RHEL/Fedora both handled):

- \`default-jdk\` (OpenJDK 17+; 21 recommended) — for \`LatBench.java\`
- \`build-essential\` / \`gcc\` — for \`microbench.c\`
- \`linux-tools-common linux-tools-\$(uname -r)\` — for \`perf\`
- *(optional, for \`run_redis.sh\`)* \`redis-server\` and \`memtier-benchmark\`

### 2. Run the A/B comparison

\`\`\`bash
# C microbench (fastest to try; ~8 GiB working set):
sudo ./scripts/run_micro.sh

# JVM version (~15 GiB working set, 20 GiB heap):
sudo ./scripts/run_jvm.sh

# AMD-native PMU events (page-table-walk counters by name, with raw-event fallback):
sudo ./scripts/run_micro_amdpmc.sh
sudo ./scripts/run_jvm_amdpmc.sh
\`\`\`

Each script runs the workload **twice** — \`THP=never\` then \`THP=always\` — and
prints a side-by-side of page-table walks, dTLB misses, peak \`AnonHugePages\`,
and seconds. Results are also written to \`/tmp/thp_results/\`.

> **Why \`sudo\`?** Toggling \`/sys/kernel/mm/transparent_hugepage/enabled\` and
> reading system-wide PMU counters with \`perf\` require root.

### 3. (Optional) Live dashboard

\`\`\`bash
# In a tmux session — top pane:
sudo ./live/live_demo.sh
# bottom pane:
sudo ./live/pmc_live.sh
\`\`\`

---

## Reading the results

A typical run on an AMD EPYC (Genoa-X class) box, 8 GiB working set:

| Metric                     | THP = never (4 KB) | THP = always (2 MB) | Effect          |
|----------------------------|-------------------:|--------------------:|-----------------|
| Page-table walks (total)   | ~1.18 B            | ~4.9 M              | **~240x fewer** |
| Walks per 1 K instructions | ~7.4               | ~0.03               | **~240x fewer** |
| Peak AnonHugePages         | ~0                 | multi-GiB           | THP active      |
| Wall-clock                 | ~20.5 s            | ~17.3 s             | **~16% faster** |

The walk-count collapse is the *mechanism*; the wall-clock improvement is the
*payoff*. On real services the wall-clock delta varies with how memory-bound the
workload is, but the page-walk reduction is consistently large.

---

## AMD PMU event reference

The \`*_amdpmc.sh\` scripts prefer symbolic AMD Zen events and fall back to raw
encodings if the kernel's event tables don't expose them:

| Symbolic                          | Raw       | Meaning                          |
|-----------------------------------|-----------|----------------------------------|
| \`ls_l1_d_tlb_miss.all\`            | \`r43FF45\` | L1 DTLB misses (all page sizes)  |
| \`ls_l1_d_tlb_miss.all_l2_miss\`    | \`r43F045\` | DTLB miss that also misses L2 TLB -> **page-table walk** |
| \`ls_l1_d_tlb_miss.tlb_reload_4k_l2_miss\`  | —  | walk that reloaded a 4 KB entry  |
| \`ls_l1_d_tlb_miss.tlb_reload_2m_l2_miss\`  | —  | walk that reloaded a 2 MB entry  |

Generic \`perf\` events (\`dTLB-loads\`, \`dTLB-load-misses\`) are used by the
non-\`amdpmc\` scripts for portability across vendors.

---

## Tuning knobs

All scripts read environment variables so you can scale to your box:

| Variable | Default (micro / jvm) | Meaning |
|----------|----------------------:|---------|
| \`GIB\`    | \`8\` / \`15\`            | working-set size in GiB (make it > L3 and > TLB reach) |
| \`STEPS\`  | \`300000000\`           | number of dependent loads to chase |
| \`HEAP\`   | \`20g\` (jvm only)      | JVM max heap |
| \`OUT\`    | \`/tmp/thp_results\`    | results directory |

Example: \`GIB=32 STEPS=500000000 sudo ./scripts/run_micro.sh\`

---

## Requirements

- Linux with \`perf\` (kernel PMU access; \`perf_event_paranoid\` low enough or root)
- A CPU with a hardware PMU (AMD Zen recommended for the native event names)
- OpenJDK 17+ for the JVM bench; a C compiler for the microbench
- Enough RAM to hold the working set **without swapping** (swapping invalidates
  the measurement)

---

## Safety / privacy

This repository is intentionally free of any infrastructure details — no host
names, IP addresses, cloud account IDs, instance IDs, tokens, or credentials.
The benchmarks read only public \`/sys\` and \`/proc\` interfaces and the CPU PMU.

## License

MIT — see [LICENSE](LICENSE).
