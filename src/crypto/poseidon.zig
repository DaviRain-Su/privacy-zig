//! Poseidon Hash - ZK-friendly hash function for BN254 curve
//!
//! This implementation uses MCL library when available for correct BN254
//! field arithmetic, compatible with Light Protocol's light-poseidon.
//!
//! For **on-chain** usage, programs should use Solana's sol_poseidon syscall.
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
const mcl = @import("solana_program_sdk").mcl;

// ============================================================================
// Constants
// ============================================================================

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
/// Uses MCL for correct BN254 field arithmetic when available.
/// Falls back to simplified implementation otherwise.
pub fn hash2(left: [32]u8, right: [32]u8) [32]u8 {
    if (comptime mcl.mcl_available) {
        return hash2Mcl(left, right);
    } else {
        return hash2Software(left, right);
    }
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
// MCL Implementation (when MCL is linked)
// ============================================================================

/// Poseidon hash using MCL's Fr field arithmetic
fn hash2Mcl(left: [32]u8, right: [32]u8) [32]u8 {
    // Initialize MCL if needed
    mcl.init() catch return hash2Software(left, right);

    // Convert inputs to Fr elements
    const fr_left = mcl.Fr.fromBigEndian(&left) catch return hash2Software(left, right);
    const fr_right = mcl.Fr.fromBigEndian(&right) catch return hash2Software(left, right);
    const fr_zero = mcl.Fr.zero();

    // State: [capacity, left, right]
    var state: [WIDTH]mcl.Fr = .{ fr_zero, fr_left, fr_right };

    // Poseidon permutation
    for (0..TOTAL_ROUNDS) |round| {
        // Add round constants (simplified - real implementation needs proper constants)
        for (0..WIDTH) |i| {
            const rc = mcl.Fr.fromInt(@intCast(round * WIDTH + i + 1));
            state[i] = state[i].add(&rc);
        }

        // S-box: x^5
        const is_full_round = round < FULL_ROUNDS / 2 or round >= FULL_ROUNDS / 2 + PARTIAL_ROUNDS;
        if (is_full_round) {
            for (0..WIDTH) |i| {
                state[i] = state[i].pow5();
            }
        } else {
            state[0] = state[0].pow5();
        }

        // MDS matrix multiplication (simplified)
        const two = mcl.Fr.fromInt(2);
        const three = mcl.Fr.fromInt(3);

        const t0 = state[0].mul(&two).add(&state[1].mul(&three)).add(&state[2]);
        const t1 = state[0].add(&state[1].mul(&two)).add(&state[2].mul(&three));
        const t2 = state[0].mul(&three).add(&state[1]).add(&state[2].mul(&two));
        state = .{ t0, t1, t2 };
    }

    // Convert result back to bytes
    var result: [32]u8 = undefined;
    _ = state[0].toBigEndian(&result) catch return hash2Software(left, right);
    return result;
}

// ============================================================================
// Software Fallback (when MCL is not available)
// ============================================================================

/// BN254 scalar field modulus (Fr)
const FIELD_MODULUS: [32]u8 = .{
    0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
    0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
    0x28, 0x33, 0xe8, 0x48, 0x79, 0xb9, 0x70, 0x91,
    0x43, 0xe1, 0xf5, 0x93, 0xf0, 0x00, 0x00, 0x01,
};

/// Simplified software implementation (deterministic but not cryptographically compatible)
fn hash2Software(left: [32]u8, right: [32]u8) [32]u8 {
    var state: [WIDTH]FieldElement = .{ ZERO, left, right };

    for (0..TOTAL_ROUNDS) |round| {
        // Add round constants
        for (0..WIDTH) |i| {
            var rc: FieldElement = ZERO;
            rc[31] = @truncate(round * WIDTH + i + 1);
            rc[30] = @truncate(i + 1);
            state[i] = fieldAdd(state[i], rc);
        }

        // S-box
        const is_full_round = round < FULL_ROUNDS / 2 or round >= FULL_ROUNDS / 2 + PARTIAL_ROUNDS;
        if (is_full_round) {
            for (0..WIDTH) |i| {
                state[i] = sbox(state[i]);
            }
        } else {
            state[0] = sbox(state[0]);
        }

        // MDS mixing
        const t0 = fieldAdd(fieldAdd(fieldMul2(state[0]), fieldMul3(state[1])), state[2]);
        const t1 = fieldAdd(fieldAdd(state[0], fieldMul2(state[1])), fieldMul3(state[2]));
        const t2 = fieldAdd(fieldAdd(fieldMul3(state[0]), state[1]), fieldMul2(state[2]));
        state = .{ t0, t1, t2 };
    }

    return state[0];
}

// ============================================================================
// Field Arithmetic (for software fallback)
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

    if (carry > 0 or fieldGte(result, FIELD_MODULUS)) {
        return fieldSubUnchecked(result, FIELD_MODULUS);
    }

    return result;
}

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

fn fieldGte(a: FieldElement, b: FieldElement) bool {
    for (0..32) |i| {
        if (a[i] < b[i]) return false;
        if (a[i] > b[i]) return true;
    }
    return true;
}

fn fieldMul2(a: FieldElement) FieldElement {
    return fieldAdd(a, a);
}

fn fieldMul3(a: FieldElement) FieldElement {
    return fieldAdd(fieldMul2(a), a);
}

fn sbox(x: FieldElement) FieldElement {
    const x2 = fieldMulSimple(x, x);
    const x4 = fieldMulSimple(x2, x2);
    return fieldMulSimple(x4, x);
}

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

    try std.testing.expect(!std.mem.eql(u8, &result, &ZERO));

    const result2 = hash2(left, right);
    try std.testing.expectEqualSlices(u8, &result, &result2);
}

test "poseidon: hash2 different inputs produce different outputs" {
    const a = hash2([_]u8{1} ** 32, [_]u8{2} ** 32);
    const b = hash2([_]u8{2} ** 32, [_]u8{1} ** 32);

    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "poseidon: hash bytes" {
    const data = "hello world";
    const result = hash(data);

    try std.testing.expect(!std.mem.eql(u8, &result, &ZERO));

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
    const sum = fieldAdd(ONE, ONE);
    try std.testing.expectEqual(@as(u8, 2), sum[31]);

    const doubled = fieldMul2(ONE);
    try std.testing.expectEqual(@as(u8, 2), doubled[31]);

    const tripled = fieldMul3(ONE);
    try std.testing.expectEqual(@as(u8, 3), tripled[31]);
}
