//! Confidential Transfer Module
//!
//! Provides privacy-preserving transfers using:
//! 1. Commitments (hide amounts)
//! 2. ZK proofs (prove validity without revealing values)
//! 3. Privacy pools (break transaction graph)

const std = @import("std");
const poseidon = @import("../crypto/poseidon.zig");
const pedersen = @import("../crypto/pedersen.zig");
const merkle = @import("../crypto/merkle.zig");
const nullifier_mod = @import("../nullifier/mod.zig");

/// Deposit note (user keeps this secret)
pub const DepositNote = struct {
    /// Secret value (random)
    secret: [32]u8,
    /// Nullifier preimage
    nullifier_preimage: [32]u8,
    /// Amount deposited
    amount: u64,
    /// Commitment (public)
    commitment: [32]u8,
    /// Leaf index in merkle tree
    leaf_index: ?u64,

    /// Generate a new deposit note
    pub fn generate(amount: u64) DepositNote {
        var secret: [32]u8 = undefined;
        var nullifier_preimage: [32]u8 = undefined;
        std.crypto.random.bytes(&secret);
        std.crypto.random.bytes(&nullifier_preimage);

        const commitment = computeCommitment(secret, nullifier_preimage, amount);

        return .{
            .secret = secret,
            .nullifier_preimage = nullifier_preimage,
            .amount = amount,
            .commitment = commitment,
            .leaf_index = null,
        };
    }

    /// Create from existing values
    pub fn fromValues(secret: [32]u8, nullifier_preimage: [32]u8, amount: u64) DepositNote {
        return .{
            .secret = secret,
            .nullifier_preimage = nullifier_preimage,
            .amount = amount,
            .commitment = computeCommitment(secret, nullifier_preimage, amount),
            .leaf_index = null,
        };
    }

    /// Get nullifier hash (revealed when withdrawing)
    pub fn getNullifierHash(self: *const DepositNote) [32]u8 {
        return poseidon.hash(&self.nullifier_preimage);
    }

    /// Verify the commitment
    pub fn verify(self: *const DepositNote) bool {
        const expected = computeCommitment(self.secret, self.nullifier_preimage, self.amount);
        return std.mem.eql(u8, &self.commitment, &expected);
    }

    /// Serialize to bytes (for storage)
    pub fn toBytes(self: *const DepositNote) [105]u8 {
        var bytes: [105]u8 = undefined;
        @memcpy(bytes[0..32], &self.secret);
        @memcpy(bytes[32..64], &self.nullifier_preimage);
        std.mem.writeInt(u64, bytes[64..72], self.amount, .little);
        @memcpy(bytes[72..104], &self.commitment);
        bytes[104] = if (self.leaf_index != null) 1 else 0;
        return bytes;
    }

    /// Deserialize from bytes
    pub fn fromBytes(bytes: [105]u8) DepositNote {
        return .{
            .secret = bytes[0..32].*,
            .nullifier_preimage = bytes[32..64].*,
            .amount = std.mem.readInt(u64, bytes[64..72], .little),
            .commitment = bytes[72..104].*,
            .leaf_index = null,
        };
    }
};

/// Withdrawal proof inputs
pub const WithdrawInput = struct {
    /// The deposit note being spent
    note: DepositNote,
    /// Merkle proof of inclusion
    merkle_proof: merkle.MerkleProof,
    /// Current merkle root
    merkle_root: [32]u8,
    /// Recipient address
    recipient: [32]u8,
    /// Relayer address (optional, for fee)
    relayer: ?[32]u8,
    /// Relayer fee
    relayer_fee: u64,
};

/// Withdrawal proof (to be verified on-chain)
pub const WithdrawProof = struct {
    /// Nullifier hash (public)
    nullifier_hash: [32]u8,
    /// Merkle root (public)
    merkle_root: [32]u8,
    /// Recipient (public)
    recipient: [32]u8,
    /// Amount (public for fixed-denomination pools, hidden for variable)
    amount: u64,
    /// Relayer (optional)
    relayer: ?[32]u8,
    /// Relayer fee
    relayer_fee: u64,
    /// ZK proof bytes (Groth16)
    proof_bytes: [256]u8,
};

/// Privacy pool configuration
pub const PoolConfig = struct {
    /// Fixed denomination (0 = variable amounts)
    fixed_denomination: u64,
    /// Merkle tree depth
    tree_depth: u8,
    /// Minimum deposit (for variable pools)
    min_deposit: u64,
    /// Maximum deposit (for variable pools)
    max_deposit: u64,
};

/// Privacy pool state
pub const PoolState = struct {
    /// Configuration
    config: PoolConfig,
    /// Current merkle root
    merkle_root: [32]u8,
    /// Number of deposits
    deposit_count: u64,
    /// Nullifier set (bloom filter for efficiency)
    nullifier_bloom: nullifier_mod.BloomFilter,
    /// Total deposited (for variable pools)
    total_deposited: u64,
};

// ============================================================================
// Core Functions
// ============================================================================

/// Compute commitment: hash(secret || nullifier_preimage || amount)
pub fn computeCommitment(secret: [32]u8, nullifier_preimage: [32]u8, amount: u64) [32]u8 {
    var amount_bytes: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, amount_bytes[24..32], amount, .big);

    const elements = [_][32]u8{ secret, nullifier_preimage, amount_bytes };
    return poseidon.hashMany(&elements);
}

/// Generate deposit instruction data
pub fn generateDepositData(commitment: [32]u8) []const u8 {
    // Return commitment as instruction data
    return &commitment;
}

/// Generate withdraw proof (off-chain)
/// In production, this would generate a real ZK proof
pub fn generateWithdrawProof(input: WithdrawInput) !WithdrawProof {
    // Verify merkle proof
    if (!input.merkle_proof.verify(input.merkle_root, input.note.commitment)) {
        return error.InvalidMerkleProof;
    }

    // Generate nullifier hash
    const nullifier_hash = input.note.getNullifierHash();

    // Generate ZK proof (placeholder - in production use Noir/Circom)
    var proof_bytes: [256]u8 = undefined;
    const proof_input = [_][32]u8{
        input.merkle_root,
        nullifier_hash,
        input.recipient,
        input.note.secret,
    };
    const proof_hash = poseidon.hashMany(&proof_input);
    @memcpy(proof_bytes[0..32], &proof_hash);
    @memset(proof_bytes[32..], 0);

    return .{
        .nullifier_hash = nullifier_hash,
        .merkle_root = input.merkle_root,
        .recipient = input.recipient,
        .amount = input.note.amount,
        .relayer = input.relayer,
        .relayer_fee = input.relayer_fee,
        .proof_bytes = proof_bytes,
    };
}

/// Verify withdraw proof (placeholder - on-chain uses ZK verifier)
pub fn verifyWithdrawProof(
    proof: *const WithdrawProof,
    pool_root: [32]u8,
    nullifier_set: *const nullifier_mod.BloomFilter,
) !void {
    // Check merkle root matches
    if (!std.mem.eql(u8, &proof.merkle_root, &pool_root)) {
        return error.InvalidMerkleRoot;
    }

    // Check nullifier not spent
    if (nullifier_set.mightContain(proof.nullifier_hash)) {
        return error.NullifierAlreadySpent;
    }

    // In production: verify ZK proof using Groth16 verifier
    // For now, just check proof bytes are not empty
    var all_zero = true;
    for (proof.proof_bytes[0..32]) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        return error.InvalidProof;
    }
}

// ============================================================================
// Fixed Denomination Pool Helpers
// ============================================================================

/// Standard pool denominations (in lamports)
pub const StandardDenominations = struct {
    pub const SOL_0_1: u64 = 100_000_000; // 0.1 SOL
    pub const SOL_1: u64 = 1_000_000_000; // 1 SOL
    pub const SOL_10: u64 = 10_000_000_000; // 10 SOL
    pub const SOL_100: u64 = 100_000_000_000; // 100 SOL
};

/// Create a fixed-denomination pool config
pub fn fixedDenominationPool(denomination: u64, depth: u8) PoolConfig {
    return .{
        .fixed_denomination = denomination,
        .tree_depth = depth,
        .min_deposit = denomination,
        .max_deposit = denomination,
    };
}

/// Create a variable amount pool config
pub fn variableAmountPool(min: u64, max: u64, depth: u8) PoolConfig {
    return .{
        .fixed_denomination = 0,
        .tree_depth = depth,
        .min_deposit = min,
        .max_deposit = max,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "transfer: deposit note generation" {
    const note = DepositNote.generate(1_000_000_000); // 1 SOL

    try std.testing.expectEqual(@as(u64, 1_000_000_000), note.amount);
    try std.testing.expect(note.verify());
    try std.testing.expect(note.leaf_index == null);
}

test "transfer: deposit note serialization" {
    const note = DepositNote.generate(500_000_000);
    const bytes = note.toBytes();
    const restored = DepositNote.fromBytes(bytes);

    try std.testing.expectEqualSlices(u8, &note.secret, &restored.secret);
    try std.testing.expectEqualSlices(u8, &note.nullifier_preimage, &restored.nullifier_preimage);
    try std.testing.expectEqual(note.amount, restored.amount);
    try std.testing.expectEqualSlices(u8, &note.commitment, &restored.commitment);
}

test "transfer: nullifier hash deterministic" {
    const note = DepositNote.generate(1_000_000);

    const hash1 = note.getNullifierHash();
    const hash2 = note.getNullifierHash();

    try std.testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "transfer: commitment computation" {
    const secret: [32]u8 = [_]u8{1} ** 32;
    const nullifier: [32]u8 = [_]u8{2} ** 32;
    const amount: u64 = 1000;

    const c1 = computeCommitment(secret, nullifier, amount);
    const c2 = computeCommitment(secret, nullifier, amount);

    // Same inputs = same commitment
    try std.testing.expectEqualSlices(u8, &c1, &c2);

    // Different amount = different commitment
    const c3 = computeCommitment(secret, nullifier, amount + 1);
    try std.testing.expect(!std.mem.eql(u8, &c1, &c3));
}

test "transfer: fixed denomination pool" {
    const config = fixedDenominationPool(StandardDenominations.SOL_1, 20);

    try std.testing.expectEqual(StandardDenominations.SOL_1, config.fixed_denomination);
    try std.testing.expectEqual(@as(u8, 20), config.tree_depth);
}

test "transfer: variable pool" {
    const config = variableAmountPool(100_000, 10_000_000_000, 20);

    try std.testing.expectEqual(@as(u64, 0), config.fixed_denomination);
    try std.testing.expectEqual(@as(u64, 100_000), config.min_deposit);
    try std.testing.expectEqual(@as(u64, 10_000_000_000), config.max_deposit);
}

test "transfer: withdraw proof generation" {
    const allocator = std.testing.allocator;

    // Create merkle tree and insert deposit
    var tree = try merkle.Tree10.init(allocator);
    defer tree.deinit();

    var note = DepositNote.generate(1_000_000_000);
    note.leaf_index = try tree.insert(note.commitment);

    // Get merkle proof
    const proof = try tree.getProof(allocator, note.leaf_index.?);
    defer {
        allocator.free(proof.path);
        allocator.free(proof.indices);
    }

    // Generate withdraw proof
    const recipient: [32]u8 = [_]u8{99} ** 32;
    const input = WithdrawInput{
        .note = note,
        .merkle_proof = proof,
        .merkle_root = tree.getRoot(),
        .recipient = recipient,
        .relayer = null,
        .relayer_fee = 0,
    };

    const withdraw_proof = try generateWithdrawProof(input);

    try std.testing.expectEqualSlices(u8, &note.getNullifierHash(), &withdraw_proof.nullifier_hash);
    try std.testing.expectEqualSlices(u8, &recipient, &withdraw_proof.recipient);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), withdraw_proof.amount);
}
