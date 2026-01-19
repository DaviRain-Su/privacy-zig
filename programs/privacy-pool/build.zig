const std = @import("std");
const solana = @import("solana_program_sdk");

pub fn build(b: *std.Build) void {
    // For BPF program build
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const target = b.resolveTargetQuery(solana.sbf_target);

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

    // BPF program (dynamic library for Solana)
    const program = b.addLibrary(.{
        .name = "privacy_pool",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    program.root_module.addImport("solana_program_sdk", sdk_mod);
    program.root_module.addImport("sol_anchor_zig", anchor_mod);

    _ = solana.buildProgram(b, program, target, optimize);
    b.installArtifact(program);

    // Native tests (host target)
    const host_sdk_dep = b.dependency("solana_program_sdk", .{
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const host_sdk_mod = host_sdk_dep.module("solana_program_sdk");

    const host_anchor_dep = b.dependency("sol_anchor_zig", .{
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const host_anchor_mod = host_anchor_dep.module("sol_anchor_zig");

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    tests.root_module.addImport("solana_program_sdk", host_sdk_mod);
    tests.root_module.addImport("sol_anchor_zig", host_anchor_mod);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
