//! Syscall wrappers using extern fn (required for BPF deployment)
//!
//! Zig 0.15's BPF target has issues with function pointer calls.
//! This module provides extern fn wrappers that work correctly.

const bpf = @import("solana_program_sdk").bpf;

/// Poseidon hash syscall
pub fn poseidon(
    params: u64,
    endianness: u64,
    vals: [*]const u8,
    vals_len: u64,
    result: [*]u8,
) u64 {
    if (bpf.is_bpf_program) {
        const Syscall = struct {
            extern fn sol_poseidon(u64, u64, [*]const u8, u64, [*]u8) callconv(.c) u64;
        };
        return Syscall.sol_poseidon(params, endianness, vals, vals_len, result);
    }
    return 1; // Error for non-BPF
}

/// BN254 group operation syscall
pub fn altBn128GroupOp(
    op: u64,
    input: [*]const u8,
    input_len: u64,
    output: [*]u8,
) u64 {
    if (bpf.is_bpf_program) {
        const Syscall = struct {
            extern fn sol_alt_bn128_group_op(u64, [*]const u8, u64, [*]u8) callconv(.c) u64;
        };
        return Syscall.sol_alt_bn128_group_op(op, input, input_len, output);
    }
    return 1; // Error for non-BPF
}

/// BN254 pairing syscall
pub fn altBn128Pairing(
    input: [*]const u8,
    input_len: u64,
    output: [*]u8,
) u64 {
    if (bpf.is_bpf_program) {
        const Syscall = struct {
            extern fn sol_alt_bn128_pairing(u64, [*]const u8, u64, [*]u8) callconv(.c) u64;
        };
        // Use alt_bn128_group_op with pairing operation code
        return Syscall.sol_alt_bn128_pairing(0, input, input_len, output);
    }
    return 1; // Error for non-BPF
}
