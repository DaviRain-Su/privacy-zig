const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const sdk_dep = b.dependency("solana_program_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const sdk_mod = sdk_dep.module("solana_program_sdk");

    const anchor_dep = b.dependency("sol_anchor_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const anchor_mod = anchor_dep.module("sol_anchor_zig");

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "solana_program_sdk", .module = sdk_mod },
                .{ .name = "sol_anchor_zig", .module = anchor_mod },
            },
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
