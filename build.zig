const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // MCL option for off-chain BN254 operations (Poseidon hash)
    const with_mcl = b.option(bool, "with-mcl", "Enable MCL library for correct BN254 field arithmetic") orelse false;

    // Get solana-program-sdk dependency with MCL option
    const solana_sdk_dep = b.dependency("solana_program_sdk", .{
        .target = target,
        .optimize = optimize,
        .@"with-mcl" = with_mcl,
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

    // Link MCL library for tests if enabled
    if (with_mcl) {
        tests.addObjectFile(solana_sdk_dep.path("vendor/mcl/lib/libmcl.a"));
        tests.root_module.addIncludePath(solana_sdk_dep.path("vendor/mcl/include"));
        tests.linkLibCpp();
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
