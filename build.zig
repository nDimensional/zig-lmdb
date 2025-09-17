const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const lmdb = b.addModule("lmdb", .{ .root_source_file = b.path("src/lib.zig") });
    const lmdb_dep = b.dependency("lmdb", .{});

    lmdb.addIncludePath(lmdb_dep.path("libraries/liblmdb"));
    lmdb.addCSourceFiles(.{
        .root = lmdb_dep.path("libraries/liblmdb"),
        .flags = &.{},
        .files = &.{ "mdb.c", "midl.c" },
    });

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    tests.root_module.addImport("lmdb", lmdb);
    const test_runner = b.addRunArtifact(tests);

    b.step("test", "Run LMDB tests").dependOn(&test_runner.step);

    // Benchmarks
    const bench = b.addExecutable(.{
        .name = "lmdb-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/main.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    bench.root_module.addImport("lmdb", lmdb);

    const bench_runner = b.addRunArtifact(bench);
    b.step("bench", "Run LMDB benchmarks").dependOn(&bench_runner.step);

    // Run example
    const exe = b.addExecutable(.{
        .name = "lmdb-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    exe.root_module.addImport("lmdb", lmdb);

    const exe_runner = b.addRunArtifact(exe);
    b.step("run", "Run example").dependOn(&exe_runner.step);
}
