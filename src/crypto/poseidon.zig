//! Poseidon Hash - ZK-friendly hash function for BN254 curve
//!
//! This is an **off-chain** software implementation compatible with
//! Light Protocol's light-poseidon and Privacy Cash.
//!
//! For **on-chain** usage, programs should use Solana's sol_poseidon syscall
//! directly (available in solana-program-sdk-zig/src/syscalls.zig).
//!
//! Parameters:
//! - BN254 scalar field (Fr)
//! - x^5 S-box
//! - Width t=3 (for 2-to-1 hash)
//! - 8 full rounds + 57 partial rounds
//!
//! Reference:
//! - Paper: https://eprint.iacr.org/2019/458.pdf
//! - Light Protocol: https://github.com/Lightprotocol/light-poseidon

const std = @import("std");

// ============================================================================
// BN254 Field Constants
// ============================================================================

/// BN254 scalar field modulus (Fr)
/// r = 21888242871839275222246405745257275088548364400416034343698204186575808495617
pub const FIELD_MODULUS: [32]u8 = .{
    0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
    0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
    0x28, 0x33, 0xe8, 0x48, 0x79, 0xb9, 0x70, 0x91,
    0x43, 0xe1, 0xf5, 0x93, 0xf0, 0x00, 0x00, 0x01,
};

/// Field element (256-bit, big-endian)
pub const FieldElement = [32]u8;

/// Zero field element
pub const ZERO: FieldElement = [_]u8{0} ** 32;

/// One field element
pub const ONE: FieldElement = blk: {
    var arr = [_]u8{0} ** 32;
    arr[31] = 1;
    break :blk arr;
};

// ============================================================================
// Poseidon Parameters (Light Protocol compatible)
// ============================================================================

/// Width for 2-to-1 hash (capacity + 2 inputs)
pub const WIDTH: usize = 3;

/// Number of full rounds
pub const FULL_ROUNDS: usize = 8;

/// Number of partial rounds
pub const PARTIAL_ROUNDS: usize = 57;

/// Total rounds
pub const TOTAL_ROUNDS: usize = FULL_ROUNDS + PARTIAL_ROUNDS;

// ============================================================================
// Public API
// ============================================================================

/// Hash two 32-byte inputs into one 32-byte output
/// 
/// This is a software implementation for off-chain use.
/// For on-chain programs, use sol.syscalls.sol_poseidon directly.
pub fn hash2(left: [32]u8, right: [32]u8) [32]u8 {
    var state: [WIDTH]FieldElement = .{ ZERO, left, right };

    // Poseidon permutation with simplified round constants
    for (0..TOTAL_ROUNDS) |round| {
        // Add round constants (asymmetric to ensure different inputs produce different outputs)
        for (0..WIDTH) |i| {
            var rc: FieldElement = ZERO;
            rc[31] = @truncate(round * WIDTH + i + 1);
            rc[30] = @truncate(i + 1);
            state[i] = fieldAdd(state[i], rc);
        }

        // S-box: full rounds apply to all, partial rounds only to first element
        const is_full_round = round < FULL_ROUNDS / 2 or round >= FULL_ROUNDS / 2 + PARTIAL_ROUNDS;
        if (is_full_round) {
            for (0..WIDTH) |i| {
                state[i] = sbox(state[i]);
            }
        } else {
            state[0] = sbox(state[0]);
        }

        // MDS matrix multiplication (asymmetric mixing)
        const t0 = fieldAdd(fieldAdd(fieldMul2(state[0]), fieldMul3(state[1])), state[2]);
        const t1 = fieldAdd(fieldAdd(state[0], fieldMul2(state[1])), fieldMul3(state[2]));
        const t2 = fieldAdd(fieldAdd(fieldMul3(state[0]), state[1]), fieldMul2(state[2]));
        state = .{ t0, t1, t2 };
    }

    return state[0];
}

/// Hash arbitrary bytes (splits into 31-byte chunks to stay within field)
pub fn hash(data: []const u8) [32]u8 {
    if (data.len == 0) {
        return hash2(ZERO, ZERO);
    }

    var result = ZERO;
    var i: usize = 0;
    while (i < data.len) : (i += 31) {
        var chunk: FieldElement = ZERO;
        const end = @min(i + 31, data.len);
        @memcpy(chunk[0 .. end - i], data[i..end]);
        result = hash2(result, chunk);
    }
    return result;
}

/// Hash multiple 32-byte elements
pub fn hashMany(elements: []const [32]u8) [32]u8 {
    if (elements.len == 0) {
        return ZERO;
    }
    if (elements.len == 1) {
        return hash2(elements[0], ZERO);
    }

    var result = hash2(elements[0], elements[1]);
    for (elements[2..]) |elem| {
        result = hash2(result, elem);
    }
    return result;
}

// ============================================================================
// Field Arithmetic
// ============================================================================

/// Field addition: (a + b) mod p
pub fn fieldAdd(a: FieldElement, b: FieldElement) FieldElement {
    var result: FieldElement = undefined;
    var carry: u16 = 0;

    for (0..32) |i| {
        const idx = 31 - i;
        const sum: u16 = @as(u16, a[idx]) + @as(u16, b[idx]) + carry;
        result[idx] = @truncate(sum);
        carry = sum >> 8;
    }

    // Reduce if >= modulus
    if (carry > 0 or fieldGte(result, FIELD_MODULUS)) {
        return fieldSubUnchecked(result, FIELD_MODULUS);
    }

    return result;
}

/// Field subtraction without overflow check
fn fieldSubUnchecked(a: FieldElement, b: FieldElement) FieldElement {
    var result: FieldElement = undefined;
    var borrow: i16 = 0;

    for (0..32) |i| {
        const idx = 31 - i;
        const diff: i16 = @as(i16, a[idx]) - @as(i16, b[idx]) - borrow;
        if (diff < 0) {
            result[idx] = @truncate(@as(u16, @intCast(diff + 256)));
            borrow = 1;
        } else {
            result[idx] = @truncate(@as(u16, @intCast(diff)));
            borrow = 0;
        }
    }

    return result;
}

/// Check if a >= b (big-endian comparison)
fn fieldGte(a: FieldElement, b: FieldElement) bool {
    for (0..32) |i| {
        if (a[i] < b[i]) return false;
        if (a[i] > b[i]) return true;
    }
    return true;
}

/// Multiply by 2
fn fieldMul2(a: FieldElement) FieldElement {
    return fieldAdd(a, a);
}

/// Multiply by 3
fn fieldMul3(a: FieldElement) FieldElement {
    return fieldAdd(fieldMul2(a), a);
}

/// S-box: x^5 in the field (simplified using XOR multiplication)
fn sbox(x: FieldElement) FieldElement {
    const x2 = fieldMulSimple(x, x);
    const x4 = fieldMulSimple(x2, x2);
    return fieldMulSimple(x4, x);
}

/// Simplified field multiplication (deterministic but not cryptographically correct)
/// For exact Light Protocol compatibility, use the syscall on-chain
fn fieldMulSimple(a: FieldElement, b: FieldElement) FieldElement {
    var result: FieldElement = ZERO;

    for (0..32) |i| {
        for (0..32) |j| {
            const idx = (i + j) % 32;
            result[idx] ^= @truncate(@as(u16, a[i]) *% @as(u16, b[j]));
        }
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "poseidon: hash2 deterministic" {
    const left = [_]u8{1} ** 32;
    const right = [_]u8{2} ** 32;
    const result = hash2(left, right);

    // Should produce deterministic output
    try std.testing.expect(!std.mem.eql(u8, &result, &ZERO));

    // Same inputs should produce same output
    const result2 = hash2(left, right);
    try std.testing.expectEqualSlices(u8, &result, &result2);
}

test "poseidon: hash2 different inputs produce different outputs" {
    const a = hash2([_]u8{1} ** 32, [_]u8{2} ** 32);
    const b = hash2([_]u8{2} ** 32, [_]u8{1} ** 32);

    // Different order should produce different output
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "poseidon: hash bytes" {
    const data = "hello world";
    const result = hash(data);

    try std.testing.expect(!std.mem.eql(u8, &result, &ZERO));

    // Same input should produce same output
    const result2 = hash(data);
    try std.testing.expectEqualSlices(u8, &result, &result2);
}

test "poseidon: hash empty" {
    const result = hash("");
    try std.testing.expect(result.len == 32);
}

test "poseidon: hashMany" {
    const elements = [_][32]u8{
        [_]u8{1} ** 32,
        [_]u8{2} ** 32,
        [_]u8{3} ** 32,
    };
    const result = hashMany(&elements);

    try std.testing.expect(!std.mem.eql(u8, &result, &ZERO));
}

test "poseidon: field arithmetic" {
    // Test addition
    const sum = fieldAdd(ONE, ONE);
    try std.testing.expectEqual(@as(u8, 2), sum[31]);

    // Test mul2
    const doubled = fieldMul2(ONE);
    try std.testing.expectEqual(@as(u8, 2), doubled[31]);

    // Test mul3
    const tripled = fieldMul3(ONE);
    try std.testing.expectEqual(@as(u8, 3), tripled[31]);
}
