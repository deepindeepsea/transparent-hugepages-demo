/*
 * microbench.c — Transparent Huge Pages (THP) demonstrator
 *
 * A dependent-load "pointer chasing" benchmark (GUPS-style) designed to stress
 * the data TLB. It allocates a large anonymous region and walks a single random
 * permutation cycle (Sattolo's algorithm) so every access depends on the prior
 * one — defeating the hardware prefetcher and forcing a near-random DRAM access
 * plus a TLB lookup on each step.
 *
 * With 4 KB base pages a multi-GB working set needs millions of TLB entries that
 * cannot be cached, so most accesses incur a hardware page-table walk. With 2 MB
 * transparent huge pages, one TLB entry covers 512x more memory, collapsing the
 * page-walk rate and cutting effective memory-access latency.
 *
 * Usage: ./microbench <working_set_GiB> <steps> [seed]
 * Output: a single JSON line on stdout with timing + throughput.
 *
 * Build: gcc -O2 -o microbench microbench.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>

static double now_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

/* 62-bit random from two rand() calls, reduced into [0, m) */
static uint64_t rnd_below(uint64_t m) {
    uint64_t r = ((uint64_t)rand() << 31) ^ (uint64_t)rand();
    return r % m;
}

int main(int argc, char **argv) {
    size_t gib    = (argc > 1) ? strtoull(argv[1], NULL, 10) : 8;
    uint64_t steps = (argc > 2) ? strtoull(argv[2], NULL, 10) : 300000000ULL;
    unsigned seed = (argc > 3) ? (unsigned)strtoul(argv[3], NULL, 10) : 12345u;

    size_t n     = gib * (1024ULL * 1024 * 1024) / sizeof(uint64_t);
    size_t bytes = n * sizeof(uint64_t);

    uint64_t *a = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (a == MAP_FAILED) { perror("mmap"); return 1; }

    /* Request huge-page backing. Honored only when THP is enabled (always/madvise);
     * a harmless no-op when THP is set to "never". */
    if (madvise(a, bytes, MADV_HUGEPAGE) != 0) {
        /* non-fatal: kernel may reject under "never"; continue regardless */
    }

    /* Initialize identity, then Sattolo shuffle -> one single cycle of length n. */
    for (size_t i = 0; i < n; i++) a[i] = i;
    srand(seed);
    for (size_t i = n - 1; i > 0; i--) {
        size_t j = (size_t)rnd_below((uint64_t)i);   /* j in [0, i-1] */
        uint64_t t = a[i]; a[i] = a[j]; a[j] = t;
    }

    /* Chase the cycle. The data dependency serializes accesses. */
    double t0 = now_s();
    uint64_t idx = 0, acc = 0;
    for (uint64_t s = 0; s < steps; s++) {
        idx = a[idx];
        acc += idx;
    }
    double t1 = now_s();

    double secs = t1 - t0;
    double mops = (double)steps / secs / 1e6;
    double ns   = secs / (double)steps * 1e9;

    /* keep acc live so the loop is not optimized away */
    fprintf(stderr, "checksum=%llu\n", (unsigned long long)acc);
    printf("{\"gib\":%zu,\"steps\":%llu,\"seconds\":%.4f,"
           "\"M_accesses_per_s\":%.2f,\"ns_per_access\":%.2f}\n",
           gib, (unsigned long long)steps, secs, mops, ns);

    munmap(a, bytes);
    return 0;
}
