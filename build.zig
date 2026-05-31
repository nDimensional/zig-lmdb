const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const lmdb = b.addModule("lmdb", .{
        .root_source_file = b.path("src/lib.zig"),
        .link_libc = true,
    });
    const lmdb_dep = b.dependency("lmdb", .{});

    lmdb.addIncludePath(lmdb_dep.path("libraries/liblmdb"));
    lmdb.addCSourceFiles(.{
        .root = lmdb_dep.path("libraries/liblmdb"),
        .flags = &.{},
        .files = &.{ "mdb.c", "midl.c" },
    });

    // Translate lmdb.h via the build system rather than the deprecated
    // `@cImport` builtin. The resulting module is imported as `c` and shared
    // by every src/*.zig file.
    const translate_c = b.addTranslateC(.{
        .root_source_file = lmdb_dep.path("libraries/liblmdb/lmdb.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lmdb.addImport("c", translate_c.createModule());

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .optimize = optimize,
            .target = target,
            .link_libc = true,
        }),
    });

    tests.root_module.addImport("lmdb", lmdb);
    const test_runner = b.addRunArtifact(tests);

    b.step("test", "Run LMDB tests").dependOn(&test_runner.step);

    // Benchmarks
    //
    // Benchmarks are meaningless in Debug, so default to ReleaseFast. Override
    // with `-Dbench-optimize=Debug` if you need to debug the benchmark itself.
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimize mode for `zig build bench` (default: ReleaseFast)",
    ) orelse .ReleaseFast;
    const bench_value_size = b.option(
        usize,
        "value-size",
        "Benchmark value payload size in bytes (default: 32)",
    ) orelse 32;
    const bench_key_size = b.option(
        usize,
        "key-size",
        "Benchmark key size in bytes (default: 4, min 4, LMDB max 511)",
    ) orelse 4;
    const bench_entries = b.option(
        usize,
        "entries",
        "Number of entries in the benchmark dataset (default: 1000)",
    ) orelse 1_000;
    const bench_options = b.addOptions();
    bench_options.addOption(usize, "value_size", bench_value_size);
    bench_options.addOption(usize, "key_size", bench_key_size);
    bench_options.addOption(usize, "entries", bench_entries);
    const bench = b.addExecutable(.{
        .name = "lmdb-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/main.zig"),
            .optimize = bench_optimize,
            .target = target,
            .link_libc = true,
        }),
    });

    bench.root_module.addImport("lmdb", lmdb);
    bench.root_module.addOptions("config", bench_options);

    const bench_runner = b.addRunArtifact(bench);
    b.step("bench", "Run LMDB benchmarks").dependOn(&bench_runner.step);

    // Run example
    const exe = b.addExecutable(.{
        .name = "lmdb-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example.zig"),
            .optimize = optimize,
            .target = target,
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("lmdb", lmdb);

    const exe_runner = b.addRunArtifact(exe);
    b.step("run", "Run example").dependOn(&exe_runner.step);
}
