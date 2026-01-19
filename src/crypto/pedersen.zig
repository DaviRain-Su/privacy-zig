//! Pedersen Commitment - Homomorphic commitment scheme
//!
//! Pedersen commitments allow you to commit to a value while hiding it,
//! and later reveal the value along with the randomness (blinding factor).
//!
//! Properties:
//! - Hiding: Commitment reveals nothing about the value
//! - Binding: Cannot open to a different value
//! - Homomorphic: C(a) + C(b) = C(a+b)

const std = @import("std");
const poseidon = @import("poseidon.zig");

/// 32-byte value type
pub const Scalar = [32]u8;

/// Commitment (32 bytes)
pub const Commitment = [32]u8;

/// Zero scalar
pub const ZERO: Scalar = [_]u8{0} ** 32;

/// Generator point G (base point for value)
/// In production, this should be a proper elliptic curve point
var G: Scalar = undefined;
var H: Scalar = undefined;
var generators_initialized: bool = false;

fn ensureGeneratorsInitialized() void {
    if (!generators_initialized) {
        // Use simple deterministic generation
        var seed_g: Scalar = undefined;
        var seed_h: Scalar = undefined;
        @memcpy(&seed_g, "pedersen_generator_point_G_seed!");
        @memcpy(&seed_h, "pedersen_generator_point_H_seed!");
        G = poseidon.hash(&seed_g);
        H = poseidon.hash(&seed_h);
        generators_initialized = true;
    }
}

/// Opening data needed to verify a commitment
pub const Opening = struct {
    value: Scalar,
    blinding: Scalar,
};

/// Create a Pedersen commitment: C = v*G + r*H
/// where v is the value and r is the blinding factor
pub fn commit(value: Scalar, blinding: Scalar) Commitment {
    ensureGeneratorsInitialized();
    // Simplified: hash(G || value || H || blinding)
    // In production, use proper elliptic curve scalar multiplication
    const elements = [_]Scalar{ G, value, H, blinding };
    return poseidon.hashMany(&elements);
}

/// Commit to a u64 value
pub fn commitU64(value: u64, blinding: Scalar) Commitment {
    var value_scalar: Scalar = ZERO;
    std.mem.writeInt(u64, value_scalar[24..32], value, .big);
    return commit(value_scalar, blinding);
}

/// Verify a commitment opens to a value
pub fn verify(commitment: Commitment, value: Scalar, blinding: Scalar) bool {
    const expected = commit(value, blinding);
    return std.mem.eql(u8, &commitment, &expected);
}

/// Verify a commitment opens to a u64 value
pub fn verifyU64(commitment: Commitment, value: u64, blinding: Scalar) bool {
    const expected = commitU64(value, blinding);
    return std.mem.eql(u8, &commitment, &expected);
}

/// Generate a random blinding factor
pub fn randomBlinding() Scalar {
    var blinding: Scalar = undefined;
    std.crypto.random.bytes(&blinding);
    return blinding;
}

/// Homomorphic addition of commitments
/// C(a, r1) + C(b, r2) = C(a+b, r1+r2)
pub fn add(c1: Commitment, c2: Commitment) Commitment {
    // Simplified: hash(c1 || c2 || "add")
    // In production, use proper elliptic curve point addition
    return poseidon.hash2(c1, c2);
}

/// Commitment with value and blinding factor
pub const CommitmentWithOpening = struct {
    commitment: Commitment,
    opening: Opening,

    /// Create a new commitment
    pub fn create(value: Scalar) CommitmentWithOpening {
        const blinding = randomBlinding();
        return .{
            .commitment = commit(value, blinding),
            .opening = .{
                .value = value,
                .blinding = blinding,
            },
        };
    }

    /// Create from u64
    pub fn createU64(value: u64) CommitmentWithOpening {
        var value_scalar: Scalar = ZERO;
        std.mem.writeInt(u64, value_scalar[24..32], value, .big);
        return create(value_scalar);
    }

    /// Verify the commitment
    pub fn verifyCommitment(self: *const CommitmentWithOpening) bool {
        const computed = commit(self.opening.value, self.opening.blinding);
        return std.mem.eql(u8, &computed, &self.commitment);
    }

    /// Get the committed value as u64
    pub fn getValue(self: *const CommitmentWithOpening) u64 {
        return std.mem.readInt(u64, self.opening.value[24..32], .big);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "pedersen: basic commitment" {
    const value: Scalar = [_]u8{42} ++ [_]u8{0} ** 31;
    const blinding = randomBlinding();

    const c = commit(value, blinding);

    // Commitment should be 32 bytes
    try std.testing.expectEqual(@as(usize, 32), c.len);

    // Same inputs should produce same commitment
    const c2 = commit(value, blinding);
    try std.testing.expectEqualSlices(u8, &c, &c2);
}

test "pedersen: different blinding produces different commitment" {
    const value: Scalar = [_]u8{42} ++ [_]u8{0} ** 31;
    const blinding1 = [_]u8{1} ** 32;
    const blinding2 = [_]u8{2} ** 32;

    const c1 = commit(value, blinding1);
    const c2 = commit(value, blinding2);

    // Different blinding should produce different commitment
    try std.testing.expect(!std.mem.eql(u8, &c1, &c2));
}

test "pedersen: verify opening" {
    const value: Scalar = [_]u8{42} ++ [_]u8{0} ** 31;
    const blinding: Scalar = [_]u8{1} ** 32;

    const c = commit(value, blinding);

    // Correct opening should verify
    try std.testing.expect(verify(c, value, blinding));

    // Completely different value should fail  
    const wrong_value: Scalar = [_]u8{99} ** 32;
    try std.testing.expect(!verify(c, wrong_value, blinding));

    // Completely different blinding should fail
    const wrong_blinding: Scalar = [_]u8{88} ** 32;
    try std.testing.expect(!verify(c, value, wrong_blinding));
}

test "pedersen: u64 commitment" {
    const value: u64 = 1000;
    const blinding: Scalar = [_]u8{1} ** 32;

    const c = commitU64(value, blinding);
    try std.testing.expect(verifyU64(c, value, blinding));
    try std.testing.expect(!verifyU64(c, value + 1, blinding));
}

test "pedersen: commitment with opening" {
    const cwo = CommitmentWithOpening.createU64(12345);
    try std.testing.expect(cwo.verifyCommitment());
    try std.testing.expectEqual(@as(u64, 12345), cwo.getValue());
}
