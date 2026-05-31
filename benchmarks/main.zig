const std = @import("std");
const allocator = std.heap.c_allocator;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");

const value_size = 8;

var prng = std.Random.DefaultPrng.init(0x0000000000000000);
var random = prng.random();

const ms: f64 = 1_000_000.0;

var stdout_buffer: [1024]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // The OS temp directory, e.g. `$TMPDIR` on macOS or `/tmp` on Linux.
    const tmp_base = init.environ_map.get("TMPDIR") orelse "/tmp";

    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);

    const log = &stdout.interface;

    _ = try log.write("## Benchmarks\n\n");
    try Context.exec(io, tmp_base, "1k entries", 1_000, log, .{});
    _ = try log.write("\n");
    try Context.exec(io, tmp_base, "50k entries", 50_000, log, .{});
    _ = try log.write("\n");
    try Context.exec(io, tmp_base, "1m entries", 1_000_000, log, .{ .map_size = 2 * 1024 * 1024 * 1024 });

    try log.flush();
}

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

const Context = struct {
    io: std.Io,
    env: lmdb.Environment,
    name: []const u8,
    size: u32,
    log: *std.Io.Writer,

    pub fn exec(io: std.Io, tmp_base: []const u8, name: []const u8, size: u32, log: *std.Io.Writer, options: lmdb.Environment.Options) !void {
        var tmp = try TmpDir.init(io, tmp_base);
        defer tmp.cleanup(io);

        const env = try lmdb.Environment.init(tmp.path(), options);
        defer env.deinit();

        const ctx = Context{ .io = io, .env = env, .name = name, .size = size, .log = log };
        try ctx.initialize();
        try ctx.printHeader();

        try ctx.getRandomEntries("get random 1 entry", 100, 1);
        try ctx.getRandomEntries("get random 100 entries", 100, 100);
        try iterateEntries(ctx, 100);
        try ctx.setRandomEntries("set random 1 entry", 100, 1);
        try ctx.setRandomEntries("set random 100 entries", 100, 100);
        try ctx.setRandomEntries("set random 1k entries", 10, 1_000);
        try ctx.setRandomEntries("set random 50k entries", 10, 50_000);
    }

    fn initialize(ctx: Context) !void {
        const txn = try ctx.env.transaction(.{ .mode = .ReadWrite });
        errdefer txn.abort();

        var key: [4]u8 = undefined;
        var value: [value_size]u8 = undefined;

        var i: u32 = 0;
        while (i < ctx.size) : (i += 1) {
            std.mem.writeInt(u32, &key, i, .big);
            std.crypto.hash.Blake3.hash(&key, &value, .{});
            try txn.set(&key, &value);
        }

        try txn.commit();
        try ctx.env.sync();
    }

    fn printHeader(ctx: Context) !void {
        try ctx.log.print("### {s}\n\n", .{ctx.name});
        try ctx.log.print(
            "| {s: <30} | {s: >10} | {s: >10} | {s: >10} | {s: >10} | {s: >8} | {s: >10} |\n",
            .{ "", "iterations", "min (ms)", "max (ms)", "avg (ms)", "std", "ops / s" },
        );
        try ctx.log.print(
            "| {s:-<30} | {s:->10} | {s:->10} | {s:->10} | {s:->10} | {s:->8} | {s:->10} |\n",
            .{ ":", ":", ":", ":", ":", ":", ":" },
        );
    }

    fn getRandomEntries(ctx: Context, comptime name: []const u8, comptime iterations: u32, comptime batch_size: usize) !void {
        var runtimes: [iterations]f64 = undefined;

        var operations: usize = 0;
        for (&runtimes) |*t| {
            const start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
            operations += batch_size;

            const txn = try ctx.env.transaction(.{ .mode = .ReadOnly });
            defer txn.abort();

            var key: [4]u8 = undefined;

            var n: u32 = 0;
            while (n < batch_size) : (n += 1) {
                std.mem.writeInt(u32, &key, random.uintLessThan(u32, ctx.size), .big);
                const value = try txn.get(&key);
                std.debug.assert(value.?.len == value_size);
            }

            t.* = @as(f64, @floatFromInt(start.untilNow(ctx.io).raw.nanoseconds)) / ms;
        }

        try ctx.printRow(name, &runtimes, operations);
    }

    fn setRandomEntries(ctx: Context, comptime name: []const u8, comptime iterations: u32, comptime batch_size: usize) !void {
        var runtimes: [iterations]f64 = undefined;

        var operations: usize = 0;
        for (&runtimes, 0..) |*t, i| {
            const start = std.Io.Clock.Timestamp.now(ctx.io, .awake);

            const txn = try ctx.env.transaction(.{ .mode = .ReadWrite });
            errdefer txn.abort();

            var key: [4]u8 = undefined;
            var seed: [12]u8 = undefined;
            var value: [8]u8 = undefined;

            std.mem.writeInt(u32, seed[0..4], ctx.size, .big);
            std.mem.writeInt(u32, seed[4..8], @as(u32, @intCast(i)), .big);

            var n: u32 = 0;
            while (n < batch_size) : (n += 1) {
                std.mem.writeInt(u32, &key, random.uintLessThan(u32, ctx.size), .big);
                std.mem.writeInt(u32, seed[8..], n, .big);
                std.crypto.hash.Blake3.hash(&seed, &value, .{});
                try txn.set(&key, &value);
            }

            try txn.commit();
            try ctx.env.sync();

            t.* = @as(f64, @floatFromInt(start.untilNow(ctx.io).raw.nanoseconds)) / ms;
            operations += batch_size;
        }

        try ctx.printRow(name, &runtimes, operations);
    }

    fn iterateEntries(ctx: Context, comptime iterations: u32) !void {
        var runtimes: [iterations]f64 = undefined;

        var operations: usize = 0;
        for (&runtimes) |*t| {
            const start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
            operations += ctx.size;

            const txn = try ctx.env.transaction(.{ .mode = .ReadOnly });
            defer txn.abort();

            const cursor = try txn.cursor();
            defer cursor.deinit();

            if (try cursor.goToFirst()) |first_key| {
                std.debug.assert(first_key.len == 4);
                const first_value = try cursor.getCurrentValue();
                std.debug.assert(first_value.len == value_size);

                while (try cursor.goToNext()) |key| {
                    std.debug.assert(key.len == 4);
                    const value = try cursor.getCurrentValue();
                    std.debug.assert(value.len == value_size);
                }
            }

            try ctx.env.sync();
            t.* = @as(f64, @floatFromInt(start.untilNow(ctx.io).raw.nanoseconds)) / ms;
        }

        try ctx.printRow("iterate over all entries", &runtimes, operations);
    }

    pub fn printRow(ctx: Context, name: []const u8, runtimes: []const f64, operations: usize) !void {
        var sum: f64 = 0;
        var min: f64 = @as(f64, @floatFromInt(std.math.maxInt(u64)));
        var max: f64 = 0;
        for (runtimes) |t| {
            sum += t;
            if (t < min) min = t;
            if (t > max) max = t;
        }

        const avg = sum / @as(f64, @floatFromInt(runtimes.len));

        var sum_sq: f64 = 0;
        for (runtimes) |t| {
            const delta = t - avg;
            sum_sq += delta * delta;
        }

        const std_dev = std.math.sqrt(sum_sq / @as(f64, @floatFromInt(runtimes.len)));
        const ops_per_second = @as(f64, @floatFromInt(operations * 1_000)) / sum;

        try ctx.log.print(
            "| {s: <30} | {d: >10} | {d: >10.4} | {d: >10.4} | {d: >10.4} | {d: >8.4} | {d: >10.0} |\n",
            .{ name, runtimes.len, min, max, avg, std_dev, ops_per_second },
        );
    }
};
