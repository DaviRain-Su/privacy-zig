const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get solana-program-sdk dependency
    const solana_sdk_dep = b.dependency("solana_program_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const solana_sdk_mod = solana_sdk_dep.module("solana_program_sdk");

    // SDK module for dependents
    const privacy_mod = b.addModule("privacy_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    privacy_mod.addImport("solana_program_sdk", solana_sdk_mod);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "solana_program_sdk", .module = solana_sdk_mod },
            },
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
