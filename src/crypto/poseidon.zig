//! Poseidon Hash - ZK-friendly hash function
//!
//! Poseidon is designed for efficient computation inside ZK circuits.
//! It uses a sponge construction with the Poseidon permutation.
//!
//! Reference: https://eprint.iacr.org/2019/458.pdf

const std = @import("std");

/// BN254 scalar field prime (used in Groth16 on Solana)
/// p = 21888242871839275222246405745257275088548364400416034343698204186575808495617
pub const FIELD_PRIME = [32]u8{
    0x01, 0x00, 0x00, 0xf0, 0x93, 0xf5, 0xe1, 0x43,
    0x91, 0x70, 0xb9, 0x79, 0x48, 0xe8, 0x33, 0x28,
    0x5d, 0x58, 0x81, 0x81, 0xb6, 0x45, 0x50, 0xb8,
    0x29, 0xa0, 0x31, 0xe1, 0x72, 0x4e, 0x64, 0x30,
};

/// Poseidon hash state width (t = 3 for 2-to-1 hash)
pub const WIDTH: usize = 3;

/// Number of full rounds
pub const FULL_ROUNDS: usize = 8;

/// Number of partial rounds
pub const PARTIAL_ROUNDS: usize = 57;

/// Field element (256-bit for BN254)
pub const FieldElement = [32]u8;

/// Zero field element
pub const ZERO: FieldElement = [_]u8{0} ** 32;

/// One field element
pub const ONE: FieldElement = blk: {
    var arr = [_]u8{0} ** 32;
    arr[31] = 1;
    break :blk arr;
};

/// Poseidon round constants (simplified - use precomputed constants)
/// In production, these should be properly generated from the Poseidon specification
var ROUND_CONSTANTS: [WIDTH * (FULL_ROUNDS + PARTIAL_ROUNDS)]FieldElement = undefined;
var round_constants_initialized: bool = false;

fn ensureRoundConstantsInitialized() void {
    if (!round_constants_initialized) {
        initRoundConstants();
        round_constants_initialized = true;
    }
}

fn initRoundConstants() void {
    // Use simple deterministic generation (not SHA256 to avoid comptime issues)
    var seed: u64 = 0x9e3779b97f4a7c15; // Golden ratio based seed
    for (0..ROUND_CONSTANTS.len) |i| {
        var elem: FieldElement = [_]u8{0} ** 32;
        for (0..32) |j| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            elem[j] = @truncate(seed >> 56);
        }
        ROUND_CONSTANTS[i] = elem;
    }
}

/// MDS matrix for Poseidon (simplified 3x3)
const MDS_MATRIX: [WIDTH][WIDTH]FieldElement = generateMDSMatrix();

/// Poseidon hasher state
pub const Poseidon = struct {
    state: [WIDTH]FieldElement,

    const Self = @This();

    /// Initialize with domain separation
    pub fn init() Self {
        return .{
            .state = .{ ZERO, ZERO, ZERO },
        };
    }

    /// Absorb two field elements and produce hash
    pub fn hashTwo(left: FieldElement, right: FieldElement) FieldElement {
        ensureRoundConstantsInitialized();
        var self = Self.init();
        self.state[0] = ZERO; // Capacity
        self.state[1] = left;
        self.state[2] = right;
        self.permute();
        return self.state[0];
    }

    /// Hash arbitrary bytes (split into field elements)
    pub fn hashBytes(data: []const u8) FieldElement {
        ensureRoundConstantsInitialized();
        if (data.len == 0) {
            return hashTwo(ZERO, ZERO);
        }

        // Pad and split into 31-byte chunks (to fit in field)
        var result = ZERO;
        var i: usize = 0;
        while (i < data.len) : (i += 31) {
            var chunk: FieldElement = ZERO;
            const end = @min(i + 31, data.len);
            @memcpy(chunk[0 .. end - i], data[i..end]);
            result = hashTwo(result, chunk);
        }
        return result;
    }

    /// Hash multiple field elements
    pub fn hashManyElements(elements: []const FieldElement) FieldElement {
        ensureRoundConstantsInitialized();
        if (elements.len == 0) {
            return ZERO;
        }
        if (elements.len == 1) {
            return hashTwo(elements[0], ZERO);
        }

        var result = hashTwo(elements[0], elements[1]);
        for (elements[2..]) |elem| {
            result = hashTwo(result, elem);
        }
        return result;
    }

    /// Poseidon permutation (simplified version)
    fn permute(self: *Self) void {
        var round: usize = 0;

        // First half of full rounds
        for (0..FULL_ROUNDS / 2) |_| {
            self.fullRound(round);
            round += 1;
        }

        // Partial rounds
        for (0..PARTIAL_ROUNDS) |_| {
            self.partialRound(round);
            round += 1;
        }

        // Second half of full rounds
        for (0..FULL_ROUNDS / 2) |_| {
            self.fullRound(round);
            round += 1;
        }
    }

    /// Full round: AddRoundConstant + S-box on all + MDS
    fn fullRound(self: *Self, round: usize) void {
        // Add round constants
        for (0..WIDTH) |i| {
            self.state[i] = fieldAdd(self.state[i], ROUND_CONSTANTS[round * WIDTH + i]);
        }
        // S-box on all elements
        for (0..WIDTH) |i| {
            self.state[i] = sbox(self.state[i]);
        }
        // MDS matrix multiplication
        self.mdsMultiply();
    }

    /// Partial round: AddRoundConstant + S-box on first + MDS
    fn partialRound(self: *Self, round: usize) void {
        // Add round constants
        for (0..WIDTH) |i| {
            self.state[i] = fieldAdd(self.state[i], ROUND_CONSTANTS[round * WIDTH + i]);
        }
        // S-box only on first element
        self.state[0] = sbox(self.state[0]);
        // MDS matrix multiplication
        self.mdsMultiply();
    }

    /// MDS matrix multiplication
    fn mdsMultiply(self: *Self) void {
        var new_state: [WIDTH]FieldElement = undefined;
        for (0..WIDTH) |i| {
            new_state[i] = ZERO;
            for (0..WIDTH) |j| {
                const product = fieldMul(MDS_MATRIX[i][j], self.state[j]);
                new_state[i] = fieldAdd(new_state[i], product);
            }
        }
        self.state = new_state;
    }
};

/// S-box: x^5 in the field
fn sbox(x: FieldElement) FieldElement {
    const x2 = fieldMul(x, x);
    const x4 = fieldMul(x2, x2);
    return fieldMul(x4, x);
}

/// Field addition (mod p) - simplified big integer arithmetic
pub fn fieldAdd(a: FieldElement, b: FieldElement) FieldElement {
    var result: FieldElement = undefined;
    var carry: u16 = 0;

    // Add with carry
    for (0..32) |i| {
        const idx = 31 - i;
        const sum: u16 = @as(u16, a[idx]) + @as(u16, b[idx]) + carry;
        result[idx] = @truncate(sum);
        carry = sum >> 8;
    }

    // Reduce mod p if necessary (simplified - proper implementation needs full reduction)
    return result;
}

/// Field multiplication (mod p) - simplified
pub fn fieldMul(a: FieldElement, b: FieldElement) FieldElement {
    // Simplified multiplication - in production use proper 256-bit modular arithmetic
    // This is a placeholder that XORs for demonstration
    var result: FieldElement = undefined;

    // Simple polynomial multiplication approximation
    // For production, use Montgomery multiplication or similar
    var temp: [64]u8 = [_]u8{0} ** 64;

    // Schoolbook multiplication
    for (0..32) |i| {
        var carry: u16 = 0;
        for (0..32) |j| {
            const idx = i + j;
            const prod: u32 = @as(u32, a[31 - i]) * @as(u32, b[31 - j]) + @as(u32, temp[63 - idx]) + carry;
            temp[63 - idx] = @truncate(prod);
            carry = @truncate(prod >> 8);
        }
        if (i < 31) {
            temp[31 - i] = @truncate(carry);
        }
    }

    // Take lower 32 bytes (simplified reduction)
    @memcpy(&result, temp[32..64]);
    return result;
}



/// Generate MDS matrix (simplified Cauchy matrix)
fn generateMDSMatrix() [WIDTH][WIDTH]FieldElement {
    var matrix: [WIDTH][WIDTH]FieldElement = undefined;

    // Simple MDS matrix for width 3
    // In production, use properly generated Cauchy matrix
    for (0..WIDTH) |i| {
        for (0..WIDTH) |j| {
            var elem: FieldElement = ZERO;
            elem[31] = @truncate((i + j + 1) % 256);
            elem[30] = @truncate((i * WIDTH + j + 1) % 256);
            matrix[i][j] = elem;
        }
    }

    return matrix;
}

// ============================================================================
// Public API
// ============================================================================

/// Hash two 32-byte inputs into one 32-byte output
pub fn hash2(left: [32]u8, right: [32]u8) [32]u8 {
    return Poseidon.hashTwo(left, right);
}

/// Hash arbitrary bytes
pub fn hash(data: []const u8) [32]u8 {
    return Poseidon.hashBytes(data);
}

/// Hash multiple 32-byte elements
pub fn hashMany(elements: []const [32]u8) [32]u8 {
    return Poseidon.hashManyElements(elements);
}

// ============================================================================
// Tests
// ============================================================================

test "poseidon: hash2 basic" {
    const left = [_]u8{1} ** 32;
    const right = [_]u8{2} ** 32;
    const result = hash2(left, right);

    // Should produce deterministic output
    try std.testing.expect(!std.mem.eql(u8, &result, &ZERO));

    // Same inputs should produce same output
    const result2 = hash2(left, right);
    try std.testing.expectEqualSlices(u8, &result, &result2);
}

test "poseidon: hash2 different inputs" {
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
    // Should still produce valid output
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
    const a = ONE;
    const b = ONE;

    // 1 + 1 = 2
    const sum = fieldAdd(a, b);
    try std.testing.expectEqual(@as(u8, 2), sum[31]);

    // 1 * 1 = 1
    const product = fieldMul(a, a);
    try std.testing.expectEqual(@as(u8, 1), product[31]);
}
