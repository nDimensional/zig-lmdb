const std = @import("std");
const allocator = std.heap.c_allocator;
const hex = std.fmt.fmtSliceHexLower;

const lmdb = @import("lmdb");

const value_size = 8;

var prng = std.Random.DefaultPrng.init(0x0000000000000000);
var random = prng.random();

const ms: f64 = 1_000_000.0;

var stdout_buffer: [1024]u8 = undefined;

pub fn main() !void {
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);

    const log = &stdout.interface;

    _ = try log.write("## Benchmarks\n\n");
    try Context.exec("1k entries", 1_000, log, .{});
    _ = try log.write("\n");
    try Context.exec("50k entries", 50_000, log, .{});
    _ = try log.write("\n");
    try Context.exec("1m entries", 1_000_000, log, .{ .map_size = 2 * 1024 * 1024 * 1024 });

    try log.flush();
}

var path_buffer: [std.fs.max_path_bytes]u8 = undefined;

fn open(dir: std.fs.Dir, options: lmdb.Environment.Options) !lmdb.Environment {
    const path = try dir.realpath(".", &path_buffer);
    path_buffer[path.len] = 0;
    return try lmdb.Environment.init(path_buffer[0..path.len :0], options);
}

const Context = struct {
    env: lmdb.Environment,
    name: []const u8,
    size: u32,
    log: *std.io.Writer,

    pub fn exec(name: []const u8, size: u32, log: *std.io.Writer, options: lmdb.Environment.Options) !void {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const env = try open(tmp.dir, options);
        defer env.deinit();

        const ctx = Context{ .env = env, .name = name, .size = size, .log = log };
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
        var timer = try std.time.Timer.start();

        var operations: usize = 0;
        for (&runtimes) |*t| {
            timer.reset();
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

            t.* = @as(f64, @floatFromInt(timer.read())) / ms;
        }

        try ctx.printRow(name, &runtimes, operations);
    }

    fn setRandomEntries(ctx: Context, comptime name: []const u8, comptime iterations: u32, comptime batch_size: usize) !void {
        var runtimes: [iterations]f64 = undefined;
        var timer = try std.time.Timer.start();

        var operations: usize = 0;
        for (&runtimes, 0..) |*t, i| {
            timer.reset();

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

            t.* = @as(f64, @floatFromInt(timer.read())) / ms;
            operations += batch_size;
        }

        try ctx.printRow(name, &runtimes, operations);
    }

    fn iterateEntries(ctx: Context, comptime iterations: u32) !void {
        var runtimes: [iterations]f64 = undefined;
        var timer = try std.time.Timer.start();

        var operations: usize = 0;
        for (&runtimes) |*t| {
            timer.reset();
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
            t.* = @as(f64, @floatFromInt(timer.read())) / ms;
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
