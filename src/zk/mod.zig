//! Zero-Knowledge Proof Helpers
//!
//! This module provides utilities for:
//! 1. Generating ZK proof inputs
//! 2. Verifying proofs (using Groth16 syscall on Solana)
//! 3. Circuit-friendly data structures
//!
//! Supported backends:
//! - Noir (via Sunspot verifier)
//! - Circom (via groth16-solana)

const std = @import("std");
const poseidon = @import("../crypto/poseidon.zig");
const merkle = @import("../crypto/merkle.zig");

/// Groth16 proof (256 bytes for BN254)
pub const Groth16Proof = struct {
    /// Proof points (A, B, C)
    data: [256]u8,

    /// Create empty proof
    pub fn empty() Groth16Proof {
        return .{ .data = [_]u8{0} ** 256 };
    }

    /// Create from bytes
    pub fn fromBytes(bytes: [256]u8) Groth16Proof {
        return .{ .data = bytes };
    }

    /// Serialize to bytes
    pub fn toBytes(self: *const Groth16Proof) [256]u8 {
        return self.data;
    }
};

/// Public inputs for ZK verification
pub const PublicInputs = struct {
    /// Input field elements (32 bytes each)
    inputs: []const [32]u8,

    /// Serialize to bytes
    pub fn toBytes(self: *const PublicInputs, allocator: std.mem.Allocator) ![]u8 {
        const size = self.inputs.len * 32;
        var bytes = try allocator.alloc(u8, size);
        for (self.inputs, 0..) |input, i| {
            @memcpy(bytes[i * 32 ..][0..32], &input);
        }
        return bytes;
    }
};

/// Membership proof inputs (for privacy pool)
pub const MembershipProofInput = struct {
    /// The leaf (commitment) being proven
    leaf: [32]u8,
    /// Merkle path siblings
    path_elements: []const [32]u8,
    /// Path indices (left=0, right=1)
    path_indices: []const u1,
    /// Expected root
    root: [32]u8,

    /// Convert from merkle proof
    pub fn fromMerkleProof(leaf: [32]u8, proof: merkle.MerkleProof, root: [32]u8) MembershipProofInput {
        return .{
            .leaf = leaf,
            .path_elements = proof.path,
            .path_indices = proof.indices,
            .root = root,
        };
    }

    /// Verify locally (for testing)
    pub fn verifyLocally(self: *const MembershipProofInput) bool {
        var current = self.leaf;
        for (self.path_elements, self.path_indices) |sibling, index| {
            current = if (index == 0)
                poseidon.hash2(current, sibling)
            else
                poseidon.hash2(sibling, current);
        }
        return std.mem.eql(u8, &current, &self.root);
    }
};

/// Withdrawal circuit inputs
pub const WithdrawCircuitInput = struct {
    // Private inputs (witness)
    secret: [32]u8,
    nullifier_preimage: [32]u8,
    path_elements: []const [32]u8,
    path_indices: []const u1,

    // Public inputs
    root: [32]u8,
    nullifier_hash: [32]u8,
    recipient: [32]u8,
    relayer: [32]u8,
    fee: u64,

    /// Generate Noir-compatible witness
    pub fn toNoirWitness(self: *const WithdrawCircuitInput, allocator: std.mem.Allocator) ![]u8 {
        // Format for Noir circuit
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();

        // Private inputs
        try writer.writeAll(&self.secret);
        try writer.writeAll(&self.nullifier_preimage);
        for (self.path_elements) |elem| {
            try writer.writeAll(&elem);
        }

        // Path indices as bits
        for (self.path_indices) |idx| {
            try writer.writeByte(idx);
        }

        return buffer.toOwnedSlice();
    }

    /// Get public inputs for verification
    pub fn getPublicInputs(self: *const WithdrawCircuitInput) [5][32]u8 {
        var fee_bytes: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u64, fee_bytes[24..32], self.fee, .big);

        return .{
            self.root,
            self.nullifier_hash,
            self.recipient,
            self.relayer,
            fee_bytes,
        };
    }
};

/// Range proof inputs (prove value is in range without revealing it)
pub const RangeProofInput = struct {
    /// The value (private)
    value: u64,
    /// Blinding factor (private)
    blinding: [32]u8,
    /// Commitment (public)
    commitment: [32]u8,
    /// Range min (public)
    min: u64,
    /// Range max (public)
    max: u64,

    /// Create range proof input
    pub fn create(value: u64, min: u64, max: u64) !RangeProofInput {
        if (value < min or value > max) {
            return error.ValueOutOfRange;
        }

        var blinding: [32]u8 = undefined;
        std.crypto.random.bytes(&blinding);

        // Compute Pedersen commitment
        var value_bytes: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u64, value_bytes[24..32], value, .big);
        const commitment = poseidon.hash2(value_bytes, blinding);

        return .{
            .value = value,
            .blinding = blinding,
            .commitment = commitment,
            .min = min,
            .max = max,
        };
    }
};

// ============================================================================
// Verification Helpers (for on-chain use)
// ============================================================================

/// Groth16 verification key (simplified)
pub const VerificationKey = struct {
    /// Alpha point
    alpha: [64]u8,
    /// Beta point
    beta: [128]u8,
    /// Gamma point
    gamma: [128]u8,
    /// Delta point
    delta: [128]u8,
    /// IC points (one per public input + 1)
    ic: []const [64]u8,
};

/// Verify Groth16 proof (placeholder - on-chain uses syscall)
pub fn verifyGroth16(
    vk: *const VerificationKey,
    proof: *const Groth16Proof,
    public_inputs: []const [32]u8,
) bool {
    // Placeholder verification
    // In production, this calls the Solana Groth16 syscall

    // Basic sanity checks
    if (public_inputs.len + 1 != vk.ic.len) {
        return false;
    }

    // Check proof is not empty
    var all_zero = true;
    for (proof.data[0..64]) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        return false;
    }

    // Placeholder: always return true for valid-looking proofs
    // Real verification happens on-chain
    return true;
}

// ============================================================================
// Circuit Input Builders
// ============================================================================

/// Build withdrawal circuit inputs
pub fn buildWithdrawInput(
    secret: [32]u8,
    nullifier_preimage: [32]u8,
    merkle_proof: merkle.MerkleProof,
    root: [32]u8,
    recipient: [32]u8,
    relayer: [32]u8,
    fee: u64,
) WithdrawCircuitInput {
    return .{
        .secret = secret,
        .nullifier_preimage = nullifier_preimage,
        .path_elements = merkle_proof.path,
        .path_indices = merkle_proof.indices,
        .root = root,
        .nullifier_hash = poseidon.hash(&nullifier_preimage),
        .recipient = recipient,
        .relayer = relayer,
        .fee = fee,
    };
}

// ============================================================================
// Noir Integration Helpers
// ============================================================================

/// Generate Noir TOML input file content
pub fn generateNoirInputToml(
    allocator: std.mem.Allocator,
    circuit_inputs: anytype,
) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    // Generate TOML format for Noir
    inline for (std.meta.fields(@TypeOf(circuit_inputs))) |field| {
        const value = @field(circuit_inputs, field.name);
        try writer.print("{s} = ", .{field.name});

        const T = @TypeOf(value);
        if (T == [32]u8) {
            try writer.print("\"0x", .{});
            for (value) |b| {
                try writer.print("{x:0>2}", .{b});
            }
            try writer.print("\"\n", .{});
        } else if (T == u64) {
            try writer.print("\"{d}\"\n", .{value});
        } else if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.child == [32]u8) {
            try writer.print("[", .{});
            for (value, 0..) |elem, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("\"0x", .{});
                for (elem) |b| {
                    try writer.print("{x:0>2}", .{b});
                }
                try writer.print("\"", .{});
            }
            try writer.print("]\n", .{});
        }
    }

    return buffer.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "zk: groth16 proof creation" {
    const proof = Groth16Proof.empty();
    try std.testing.expectEqual(@as(usize, 256), proof.data.len);

    const bytes = proof.toBytes();
    const restored = Groth16Proof.fromBytes(bytes);
    try std.testing.expectEqualSlices(u8, &proof.data, &restored.data);
}

test "zk: membership proof input" {
    const allocator = std.testing.allocator;

    var tree = try merkle.Tree10.init(allocator);
    defer tree.deinit();

    const leaf: [32]u8 = [_]u8{42} ** 32;
    _ = try tree.insert(leaf);

    const proof = try tree.getProof(allocator, 0);
    defer {
        allocator.free(proof.path);
        allocator.free(proof.indices);
    }

    const input = MembershipProofInput.fromMerkleProof(leaf, proof, tree.getRoot());
    try std.testing.expect(input.verifyLocally());
}

test "zk: range proof input" {
    const input = try RangeProofInput.create(500, 0, 1000);
    try std.testing.expectEqual(@as(u64, 500), input.value);
    try std.testing.expectEqual(@as(u64, 0), input.min);
    try std.testing.expectEqual(@as(u64, 1000), input.max);
}

test "zk: range proof out of range" {
    try std.testing.expectError(error.ValueOutOfRange, RangeProofInput.create(1500, 0, 1000));
}

test "zk: withdraw circuit inputs" {
    const allocator = std.testing.allocator;

    var tree = try merkle.Tree10.init(allocator);
    defer tree.deinit();

    const secret: [32]u8 = [_]u8{1} ** 32;
    const nullifier_preimage: [32]u8 = [_]u8{2} ** 32;
    const commitment = poseidon.hashMany(&[_][32]u8{ secret, nullifier_preimage });

    _ = try tree.insert(commitment);

    const proof = try tree.getProof(allocator, 0);
    defer {
        allocator.free(proof.path);
        allocator.free(proof.indices);
    }

    const recipient: [32]u8 = [_]u8{3} ** 32;
    const relayer: [32]u8 = [_]u8{0} ** 32;

    const input = buildWithdrawInput(
        secret,
        nullifier_preimage,
        proof,
        tree.getRoot(),
        recipient,
        relayer,
        0,
    );

    try std.testing.expectEqualSlices(u8, &secret, &input.secret);
    try std.testing.expectEqualSlices(u8, &recipient, &input.recipient);

    const public_inputs = input.getPublicInputs();
    try std.testing.expectEqualSlices(u8, &tree.getRoot(), &public_inputs[0]);
}

test "zk: public inputs serialization" {
    const allocator = std.testing.allocator;

    const inputs = [_][32]u8{
        [_]u8{1} ** 32,
        [_]u8{2} ** 32,
    };

    const public_inputs = PublicInputs{ .inputs = &inputs };
    const bytes = try public_inputs.toBytes(allocator);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 64), bytes.len);
}
