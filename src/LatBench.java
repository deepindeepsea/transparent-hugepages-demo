/*
 * LatBench.java — Transparent Huge Pages (THP) demonstrator for the JVM.
 *
 * Mirrors the customer scenario: a large on-heap data structure walked with a
 * random, dependent-load ("pointer chasing") pattern that defeats the hardware
 * prefetcher and thrashes the data TLB. With 4 KB base pages a multi-GB heap
 * needs far more TLB entries than the CPU can cache, so most accesses incur a
 * hardware page-table walk. With 2 MB transparent huge pages (requested by the
 * JVM via -XX:+UseTransparentHugePages and faulted up front by
 * -XX:+AlwaysPreTouch), one TLB entry covers 512x more memory, collapsing the
 * page-walk rate and cutting effective memory-access latency.
 *
 * Usage: java -cp . LatBench <workingSetGiB> <steps> [seed]
 * Output: one JSON line on stdout; "checksum=" on stderr (keeps loop live).
 *
 * Build: javac LatBench.java
 */
public class LatBench {
    public static void main(String[] args) {
        double gib   = args.length > 0 ? Double.parseDouble(args[0]) : 15.0;
        long   steps = args.length > 1 ? Long.parseLong(args[1])    : 300_000_000L;
        long   seed  = args.length > 2 ? Long.parseLong(args[2])    : 12345L;

        long nL = (long) (gib * (1L << 30) / 8L);          // 8 bytes per long
        if (nL > Integer.MAX_VALUE - 8) nL = Integer.MAX_VALUE - 8;
        int N = (int) nL;

        long[] a = new long[N];                            // the large heap region
        for (int i = 0; i < N; i++) a[i] = i;              // identity

        // Sattolo's algorithm -> a single permutation cycle of length N.
        java.util.Random r = new java.util.Random(seed);
        for (int i = N - 1; i > 0; i--) {
            int j = (int) Math.floorMod(r.nextLong(), (long) i);  // j in [0, i-1]
            long t = a[i]; a[i] = a[j]; a[j] = t;
        }

        // Chase the cycle. The data dependency serializes the accesses.
        long t0 = System.nanoTime();
        int idx = 0; long acc = 0;
        for (long s = 0; s < steps; s++) { idx = (int) a[idx]; acc += idx; }
        long t1 = System.nanoTime();

        double secs = (t1 - t0) / 1e9;
        double mops = steps / secs / 1e6;
        double ns   = secs / steps * 1e9;

        System.err.println("checksum=" + acc);            // keep acc live
        System.out.printf(
            "{\"lang\":\"java\",\"gib\":%.1f,\"elems\":%d,\"steps\":%d," +
            "\"seconds\":%.4f,\"M_accesses_per_s\":%.2f,\"ns_per_access\":%.2f}%n",
            gib, (long) N, steps, secs, mops, ns);
    }
}
