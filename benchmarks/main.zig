const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

const lmdb = @import("lmdb");

const gpa = std.heap.c_allocator;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Fixed value payload size, set at build time with `-Dvalue-size=N`. Reasonably
/// small values keep these numbers dominated by tree-traversal + transaction
/// overhead rather than bulk data movement; values large enough to spill onto
/// LMDB overflow pages (roughly half a page, ~8 KiB here) are a different code
/// path not covered here.
const value_size = config.value_size;

/// Number of key/value entries loaded into the database, set at build time with
/// `-Dentries=N`. The benchmark runs against this single dataset size.
const entries: u32 = @intCast(config.entries);

/// Map size reservation. On 64-bit the mapping is sparse and lazily backed, so
/// we over-provision generously to absorb the copy-on-write page churn of a
/// large random-order insert performed in a single transaction.
const map_size: usize = @max(256 << 20, @as(usize, entries) * (key_size + value_size + 96) * 8);

/// Number of timed samples for per-operation latency benchmarks.
const latency_samples = 100_000;
/// Iterations discarded before timing, to warm the page cache and CPU.
const warmup = 2_000;
/// Samples for the durable-commit benchmark (each one fsyncs, so keep it small).
const durable_samples = 2_000;
/// Per-thread operation count for the concurrency benchmark.
const concurrency_ops = 200_000;
/// Thread counts to sweep (clamped to the machine's CPU count at runtime).
const thread_counts = [_]usize{ 1, 2, 4, 8 };

// ---------------------------------------------------------------------------
// Timing & statistics
// ---------------------------------------------------------------------------

const Clock: std.Io.Clock = .awake;

inline fn now(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, Clock);
}

inline fn elapsedNs(io: std.Io, start: std.Io.Clock.Timestamp) u64 {
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

/// A latency distribution, summarized as percentiles in microseconds.
///
/// Percentiles describe the shape of a right-skewed latency distribution far
/// better than mean ± stddev: p50 is the typical case, p99/p99.9 are the tail
/// latencies that dominate real-world request timeouts.
const Latency = struct {
    n: usize,
    p50: f64,
    p90: f64,
    p99: f64,
    p999: f64,
    max: f64,

    /// Consumes `samples_ns` (sorts it in place).
    fn compute(samples_ns: []u64) Latency {
        std.mem.sort(u64, samples_ns, {}, std.sort.asc(u64));
        return .{
            .n = samples_ns.len,
            .p50 = percentileUs(samples_ns, 0.50),
            .p90 = percentileUs(samples_ns, 0.90),
            .p99 = percentileUs(samples_ns, 0.99),
            .p999 = percentileUs(samples_ns, 0.999),
            .max = @as(f64, @floatFromInt(samples_ns[samples_ns.len - 1])) / 1000.0,
        };
    }

    fn print(self: Latency, log: *std.Io.Writer, name: []const u8) !void {
        try log.print(
            "| {s: <34} | {d: >9} | {d: >9.3} | {d: >9.3} | {d: >9.3} | {d: >9.3} | {d: >9.3} |\n",
            .{ name, self.n, self.p50, self.p90, self.p99, self.p999, self.max },
        );
    }
};

/// Linear-interpolated percentile of a sorted sample array, returned in µs.
fn percentileUs(sorted_ns: []const u64, q: f64) f64 {
    if (sorted_ns.len == 0) return 0;
    if (sorted_ns.len == 1) return @as(f64, @floatFromInt(sorted_ns[0])) / 1000.0;

    const rank = q * @as(f64, @floatFromInt(sorted_ns.len - 1));
    const lo: usize = @intFromFloat(@floor(rank));
    const frac = rank - @floor(rank);

    const a: f64 = @floatFromInt(sorted_ns[lo]);
    const b: f64 = @floatFromInt(sorted_ns[@min(lo + 1, sorted_ns.len - 1)]);
    return (a + (b - a) * frac) / 1000.0;
}

fn opsPerSecond(ops: usize, ns: u64) f64 {
    const seconds = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
    return @as(f64, @floatFromInt(ops)) / seconds;
}

/// Formats a count with a metric suffix and 3 significant figures, e.g.
/// 892_000 -> "892k", 1_570_000 -> "1.57M", 121_832_359 -> "122M".
fn humanCount(buf: []u8, count: f64) []const u8 {
    const units = [_][]const u8{ "", "k", "M", "G", "T" };
    var v = count;
    var i: usize = 0;
    while (v >= 1000.0 and i + 1 < units.len) : (i += 1) v /= 1000.0;
    const suffix = units[i];

    // Choose decimals so the mantissa always carries 3 significant figures.
    const result = if (i == 0)
        std.fmt.bufPrint(buf, "{d:.0}", .{v})
    else if (v >= 100.0)
        std.fmt.bufPrint(buf, "{d:.0}{s}", .{ v, suffix })
    else if (v >= 10.0)
        std.fmt.bufPrint(buf, "{d:.1}{s}", .{ v, suffix })
    else
        std.fmt.bufPrint(buf, "{d:.2}{s}", .{ v, suffix });

    return result catch buf[0..0];
}

// ---------------------------------------------------------------------------
// Keys & values
// ---------------------------------------------------------------------------

/// Key size in bytes, set at build time with `-Dkey-size=N`. Must be at least 4
/// (keys encode a u32 index) and at most LMDB's `MDB_MAXKEYSIZE` of 511.
const key_size = config.key_size;

comptime {
    if (key_size < 4) @compileError("-Dkey-size must be at least 4 (keys encode a u32 index)");
    if (key_size > 511) @compileError("-Dkey-size must be at most 511 (LMDB's default MDB_MAXKEYSIZE)");
}

/// Encodes the index `x` as a big-endian u32 in the leading 4 bytes, zero-padding
/// the rest. Big-endian keeps lexicographic (memcmp) order matching numeric order
/// — so ascending indices produce ascending keys, which cursor scans rely on —
/// and the varying bytes lead so keys diverge early rather than sharing a long
/// common prefix. At the default size of 4 there is no padding.
inline fn writeKey(buf: *[key_size]u8, x: u32) void {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], x, .big);
}

/// A reusable value payload. Its contents are irrelevant to LMDB, so a fixed
/// pattern lets us keep value generation out of the timed regions.
const value: [value_size]u8 = @splat(0x5a);

// ---------------------------------------------------------------------------
// Temporary directory under the OS temp dir
// ---------------------------------------------------------------------------

/// A uniquely-named temporary directory under the OS temp directory, deleted on
/// `cleanup`. Owns its path string so it can be handed directly to LMDB, which
/// takes a null-terminated path rather than an open directory handle.
const TmpDir = struct {
    buffer: [std.Io.Dir.max_path_bytes]u8,
    len: usize,

    const random_bytes_count = 12;
    const suffix_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    fn init(io: std.Io, base: []const u8) !TmpDir {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var suffix: [suffix_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&suffix, &random_bytes);

        var self: TmpDir = .{ .buffer = undefined, .len = 0 };
        const dir_path = try std.fmt.bufPrintZ(&self.buffer, "{s}/zig-lmdb-bench-{s}", .{
            std.mem.trimEnd(u8, base, "/"),
            suffix,
        });
        self.len = dir_path.len;

        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        return self;
    }

    fn path(self: *const TmpDir) [:0]const u8 {
        return self.buffer[0..self.len :0];
    }

    fn cleanup(self: *TmpDir, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.path()) catch {};
        self.* = undefined;
    }
};

/// A populated environment plus the temp dir backing it, for read benchmarks.
const Fixture = struct {
    tmp: TmpDir,
    env: lmdb.Environment,

    /// Creates a fresh environment and bulk-loads keys `0..entries` in ascending
    /// order (a single transaction). This setup is not timed.
    fn load(io: std.Io, tmp_base: []const u8) !Fixture {
        var tmp = try TmpDir.init(io, tmp_base);
        errdefer tmp.cleanup(io);

        const env = try lmdb.Environment.init(tmp.path(), .{ .map_size = map_size });
        errdefer env.deinit();

        const txn = try env.transaction(.{ .mode = .ReadWrite });
        errdefer txn.abort();
        const db = try txn.database(null, .{});

        var key: [key_size]u8 = undefined;
        var i: u32 = 0;
        while (i < entries) : (i += 1) {
            writeKey(&key, i);
            try db.set(&key, &value);
        }
        try txn.commit();

        return .{ .tmp = tmp, .env = env };
    }

    fn deinit(self: *Fixture, io: std.Io) void {
        self.env.deinit();
        self.tmp.cleanup(io);
    }
};

// ---------------------------------------------------------------------------
// Read benchmarks (latency)
// ---------------------------------------------------------------------------

/// Point-lookup latency inside a single long-lived read transaction: isolates
/// the cost of a `get` from transaction setup.
fn getSharedTxn(io: std.Io, env: lmdb.Environment, query: []const u32) !Latency {
    const txn = try env.transaction(.{ .mode = .ReadOnly });
    defer txn.abort();
    const db = try txn.database(null, .{});

    var key: [key_size]u8 = undefined;
    var checksum: u64 = 0;

    for (0..warmup) |i| {
        writeKey(&key, query[i % query.len]);
        if (try db.get(&key)) |v| checksum +%= v[0];
    }

    const samples = try gpa.alloc(u64, latency_samples);
    defer gpa.free(samples);

    for (samples, 0..) |*s, i| {
        writeKey(&key, query[i % query.len]);
        const start = now(io);
        const v = try db.get(&key);
        s.* = elapsedNs(io, start);
        if (v) |bytes| checksum +%= bytes[0];
    }

    std.mem.doNotOptimizeAway(checksum);
    return Latency.compute(samples);
}

/// Point-lookup latency with a fresh read transaction (and dbi handle) per
/// operation: includes transaction begin/abort overhead, the realistic cost
/// when each lookup is its own unit of work.
fn getPerTxn(io: std.Io, env: lmdb.Environment, query: []const u32) !Latency {
    var key: [key_size]u8 = undefined;
    var checksum: u64 = 0;

    for (0..warmup) |i| {
        writeKey(&key, query[i % query.len]);
        const txn = try env.transaction(.{ .mode = .ReadOnly });
        const db = try txn.database(null, .{});
        if (try db.get(&key)) |v| checksum +%= v[0];
        txn.abort();
    }

    const samples = try gpa.alloc(u64, latency_samples);
    defer gpa.free(samples);

    for (samples, 0..) |*s, i| {
        writeKey(&key, query[i % query.len]);
        const start = now(io);
        const txn = try env.transaction(.{ .mode = .ReadOnly });
        const db = try txn.database(null, .{});
        const v = try db.get(&key);
        txn.abort();
        s.* = elapsedNs(io, start);
        if (v) |bytes| checksum +%= bytes[0];
    }

    std.mem.doNotOptimizeAway(checksum);
    return Latency.compute(samples);
}

/// Durable single-key write latency: begin → put → commit (which fsyncs under
/// LMDB's default flags) for one key per transaction. This is dominated by the
/// storage device's fsync latency, *not* by LMDB — see the README note.
fn durableCommit(io: std.Io, env: lmdb.Environment, query: []const u32) !Latency {
    const samples = try gpa.alloc(u64, durable_samples);
    defer gpa.free(samples);

    var key: [key_size]u8 = undefined;
    for (samples, 0..) |*s, i| {
        writeKey(&key, query[i % query.len]);
        const start = now(io);
        const txn = try env.transaction(.{ .mode = .ReadWrite });
        const db = try txn.database(null, .{});
        try db.set(&key, &value);
        try txn.commit();
        s.* = elapsedNs(io, start);
    }

    return Latency.compute(samples);
}

// ---------------------------------------------------------------------------
// Throughput benchmarks
// ---------------------------------------------------------------------------

/// Full ordered scan via a cursor; returns entries/second (best of `reps`).
fn fullScan(io: std.Io, env: lmdb.Environment, size: u32, reps: usize) !f64 {
    var best_ns: u64 = std.math.maxInt(u64);
    var checksum: u64 = 0;

    for (0..reps) |_| {
        const txn = try env.transaction(.{ .mode = .ReadOnly });
        const db = try txn.database(null, .{});
        const cursor = try db.cursor();

        const start = now(io);
        var k = try cursor.goToFirst();
        while (k) |key| : (k = try cursor.goToNext()) {
            const v = try cursor.getCurrentValue();
            checksum +%= key[0] +% v[0];
        }
        const ns = elapsedNs(io, start);

        cursor.deinit();
        txn.abort();
        best_ns = @min(best_ns, ns);
    }

    std.mem.doNotOptimizeAway(checksum);
    return opsPerSecond(size, best_ns);
}

/// Overwrite every key once, in random order, in a single transaction (one
/// fsync amortized over the whole batch). Returns writes/second (best of
/// `reps`). Same-size overwrites don't grow the tree, so this is the cheap
/// write path — compare against `insertNewKeys` for the page-splitting case.
fn overwriteAll(io: std.Io, env: lmdb.Environment, order: []const u32, reps: usize) !f64 {
    var best_ns: u64 = std.math.maxInt(u64);

    for (0..reps) |_| {
        const txn = try env.transaction(.{ .mode = .ReadWrite });
        const db = try txn.database(null, .{});

        var key: [key_size]u8 = undefined;
        const start = now(io);
        for (order) |x| {
            writeKey(&key, x);
            try db.set(&key, &value);
        }
        try txn.commit();
        const ns = elapsedNs(io, start);

        best_ns = @min(best_ns, ns);
    }

    return opsPerSecond(order.len, best_ns);
}

/// Bulk-insert `order.len` brand-new keys into a fresh environment in a single
/// transaction. With `order` ascending this is the append-friendly best case;
/// with `order` shuffled it scatters inserts across the tree, forcing page
/// splits throughout — the realistic cost of growing a dataset. Returns
/// inserts/second (best of `reps`).
fn insertNewKeys(io: std.Io, tmp_base: []const u8, order: []const u32, reps: usize) !f64 {
    var best_ns: u64 = std.math.maxInt(u64);

    for (0..reps) |_| {
        var tmp = try TmpDir.init(io, tmp_base);
        defer tmp.cleanup(io);
        const env = try lmdb.Environment.init(tmp.path(), .{ .map_size = map_size });
        defer env.deinit();

        const txn = try env.transaction(.{ .mode = .ReadWrite });
        const db = try txn.database(null, .{});

        var key: [key_size]u8 = undefined;
        const start = now(io);
        for (order) |x| {
            writeKey(&key, x);
            try db.set(&key, &value);
        }
        try txn.commit();
        const ns = elapsedNs(io, start);

        best_ns = @min(best_ns, ns);
    }

    return opsPerSecond(order.len, best_ns);
}

// ---------------------------------------------------------------------------
// Concurrency benchmark
// ---------------------------------------------------------------------------

const Reader = struct {
    env: lmdb.Environment,
    query: []const u32,
    start_offset: usize,
    ops: usize,
    checksum: u64 = 0,

    fn run(self: *Reader) void {
        // Each thread opens its own read transaction; LMDB readers are
        // lock-free and don't block each other or the writer (MVCC).
        const txn = self.env.transaction(.{ .mode = .ReadOnly }) catch return;
        defer txn.abort();
        const db = txn.database(null, .{}) catch return;

        var key: [key_size]u8 = undefined;
        var sum: u64 = 0;
        for (0..self.ops) |i| {
            const x = self.query[(self.start_offset + i) % self.query.len];
            writeKey(&key, x);
            if (db.get(&key) catch null) |v| sum +%= v[0];
        }
        self.checksum = sum;
    }
};

/// Aggregate point-read throughput with `n` concurrent reader threads. Returns
/// total reads/second. Near-linear scaling here is LMDB's headline property.
fn concurrentReads(io: std.Io, env: lmdb.Environment, query: []const u32, n: usize) !f64 {
    const readers = try gpa.alloc(Reader, n);
    defer gpa.free(readers);
    const threads = try gpa.alloc(std.Thread, n);
    defer gpa.free(threads);

    for (readers, 0..) |*r, i| {
        r.* = .{
            .env = env,
            .query = query,
            .start_offset = i * (query.len / @max(n, 1)),
            .ops = concurrency_ops,
        };
    }

    const start = now(io);
    for (threads, readers) |*t, *r| t.* = try std.Thread.spawn(.{}, Reader.run, .{r});
    for (threads) |t| t.join();
    const ns = elapsedNs(io, start);

    var checksum: u64 = 0;
    for (readers) |r| checksum +%= r.checksum;
    std.mem.doNotOptimizeAway(checksum);

    return opsPerSecond(n * concurrency_ops, ns);
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

var stdout_buffer: [4096]u8 = undefined;

fn latencyHeader(log: *std.Io.Writer, title: []const u8) !void {
    try log.print("**{s}** (microseconds)\n\n", .{title});
    try log.print(
        "| {s: <34} | {s: >9} | {s: >9} | {s: >9} | {s: >9} | {s: >9} | {s: >9} |\n",
        .{ "", "samples", "p50", "p90", "p99", "p99.9", "max" },
    );
    try log.print(
        "| {s:-<34} | {s:->9} | {s:->9} | {s:->9} | {s:->9} | {s:->9} | {s:->9} |\n",
        .{ ":", ":", ":", ":", ":", ":", ":" },
    );
}

fn throughputRow(log: *std.Io.Writer, name: []const u8, ops_per_s: f64) !void {
    var buf: [32]u8 = undefined;
    try log.print("| {s: <44} | {s: >9} |\n", .{ name, humanCount(&buf, ops_per_s) });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // The OS temp directory, e.g. `$TMPDIR` on macOS or `/tmp` on Linux.
    const tmp_base = init.environ_map.get("TMPDIR") orelse "/tmp";

    const cpu_count = std.Thread.getCpuCount() catch 1;

    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const log = &stdout.interface;

    try log.print("## {d} entries (key {d}B, value {d}B)\n\n", .{ entries, key_size, value_size });
    try log.flush();

    // Precompute a random query stream (existing keys) and a random insertion
    // order (a permutation of every key), outside any timed region.
    const query = try gpa.alloc(u32, latency_samples);
    defer gpa.free(query);
    const ascending = try gpa.alloc(u32, entries);
    defer gpa.free(ascending);
    const shuffled = try gpa.alloc(u32, entries);
    defer gpa.free(shuffled);
    {
        var prng = std.Random.DefaultPrng.init(0x5eed);
        const rand = prng.random();
        for (query) |*q| q.* = rand.uintLessThan(u32, entries);
        for (ascending, shuffled, 0..) |*a, *s, i| {
            a.* = @intCast(i);
            s.* = @intCast(i);
        }
        rand.shuffle(u32, shuffled);
    }

    // Scan reps scale inversely with the dataset size to keep wall-clock bounded.
    const scan_reps = std.math.clamp(20_000_000 / entries, 5, 2_000);
    const write_reps = 3;

    var fixture = try Fixture.load(io, tmp_base);
    defer fixture.deinit(io);
    const env = fixture.env;

    // --- Latency ---
    try latencyHeader(log, "Operation latency");
    try (try getSharedTxn(io, env, query)).print(log, "get (shared read txn)");
    try (try getPerTxn(io, env, query)).print(log, "get (new read txn per op)");
    try (try durableCommit(io, env, query)).print(log, "durable commit (1 write/txn)");
    try log.print("\n", .{});
    try log.flush();

    // --- Throughput ---
    try log.print("**Throughput** (operations/second)\n\n", .{});
    try log.print("| {s: <44} | {s: >9} |\n", .{ "", "ops / s" });
    try log.print("| {s:-<44} | {s:->9} |\n", .{ ":", ":" });
    try throughputRow(log, "full scan (cursor)", try fullScan(io, env, entries, scan_reps));
    try throughputRow(log, "overwrite all keys, random order (1 txn)", try overwriteAll(io, env, shuffled, write_reps));
    try throughputRow(log, "insert new keys, ascending (1 txn)", try insertNewKeys(io, tmp_base, ascending, write_reps));
    try throughputRow(log, "insert new keys, random order (1 txn)", try insertNewKeys(io, tmp_base, shuffled, write_reps));
    try log.print("\n", .{});
    try log.flush();

    // --- Concurrent reads ---
    try log.print("**Concurrent reads** ({d} CPUs available)\n\n", .{cpu_count});
    try log.print(
        "| {s: >7} | {s: >13} | {s: >13} | {s: >8} |\n",
        .{ "threads", "total reads/s", "per-thread/s", "scaling" },
    );
    try log.print(
        "| {s:->7} | {s:->13} | {s:->13} | {s:->8} |\n",
        .{ ":", ":", ":", ":" },
    );
    var baseline: f64 = 0;
    for (thread_counts) |n| {
        if (n > cpu_count) continue;
        const total = try concurrentReads(io, env, query, n);
        if (n == 1) baseline = total;
        var total_buf: [32]u8 = undefined;
        var per_buf: [32]u8 = undefined;
        try log.print(
            "| {d: >7} | {s: >13} | {s: >13} | {d: >7.2}x |\n",
            .{
                n,
                humanCount(&total_buf, total),
                humanCount(&per_buf, total / @as(f64, @floatFromInt(n))),
                total / baseline,
            },
        );
    }
    try log.print("\n", .{});
    try log.flush();

    // --- Storage ---
    const stat = try env.stat();
    const total_pages = stat.branch_pages + stat.leaf_pages + stat.overflow_pages;
    const data_bytes = total_pages * stat.psize;
    const bytes_per_entry = @as(f64, @floatFromInt(data_bytes)) /
        @as(f64, @floatFromInt(@max(stat.entries, 1)));
    try log.print("**Storage** (after loading {d} entries)\n\n", .{stat.entries});
    try log.print(
        "| {s: >9} | {s: >5} | {s: >8} | {s: >8} | {s: >8} | {s: >10} | {s: >11} |\n",
        .{ "page size", "depth", "branch", "leaf", "overflow", "data (KiB)", "bytes/entry" },
    );
    try log.print(
        "| {s:->9} | {s:->5} | {s:->8} | {s:->8} | {s:->8} | {s:->10} | {s:->11} |\n",
        .{ ":", ":", ":", ":", ":", ":", ":" },
    );
    try log.print(
        "| {d: >9} | {d: >5} | {d: >8} | {d: >8} | {d: >8} | {d: >10.1} | {d: >11.1} |\n",
        .{
            stat.psize,
            stat.depth,
            stat.branch_pages,
            stat.leaf_pages,
            stat.overflow_pages,
            @as(f64, @floatFromInt(data_bytes)) / 1024.0,
            bytes_per_entry,
        },
    );
    try log.print("\n", .{});
    try log.flush();
}
