//! Privacy SDK for Zig - High-performance privacy primitives for Solana
//!
//! This SDK provides:
//! - Stealth Addresses: Receive payments without revealing identity
//! - ZK Proofs: Generate and verify zero-knowledge proofs
//! - Confidential Transfers: Hide transaction amounts
//! - Nullifier Management: Prevent double-spending
//!
//! Built for use with anchor-zig for maximum performance on Solana.
//!
//! ## Quick Start
//!
//! ```zig
//! const privacy = @import("privacy_zig");
//!
//! // 1. Stealth Address
//! const wallet = privacy.stealth.StealthWallet.generate();
//! const meta = wallet.getMetaAddress();
//! const result = privacy.stealth.generateStealthAddress(meta);
//!
//! // 2. Privacy Pool Deposit
//! const note = privacy.transfer.DepositNote.generate(1_000_000_000);
//! // Submit note.commitment to on-chain pool
//!
//! // 3. Generate Nullifier
//! const nullifier = privacy.nullifier.Nullifier.generate();
//! ```

const std = @import("std");

// ============================================================================
// Core Crypto Primitives
// ============================================================================

/// Poseidon hash - ZK-friendly hash function
pub const poseidon = @import("crypto/poseidon.zig");

/// Merkle tree for membership proofs
pub const merkle = @import("crypto/merkle.zig");

/// Pedersen commitments for hiding values
pub const pedersen = @import("crypto/pedersen.zig");

// ============================================================================
// Privacy Modules
// ============================================================================

/// Stealth address generation and scanning
pub const stealth = @import("stealth/mod.zig");

/// Nullifier management (prevent double-spending)
pub const nullifier = @import("nullifier/mod.zig");

/// Confidential transfers and privacy pools
pub const transfer = @import("transfer/mod.zig");

/// Zero-knowledge proof helpers
pub const zk = @import("zk/mod.zig");

/// Confidential payments - hide amounts on-chain
pub const confidential = @import("confidential/mod.zig");

// ============================================================================
// Re-exports for convenience
// ============================================================================

/// Hash type (32 bytes)
pub const Hash = [32]u8;

/// Zero hash
pub const ZERO_HASH: Hash = [_]u8{0} ** 32;

/// Generate random bytes
pub fn randomBytes(comptime len: usize) [len]u8 {
    var bytes: [len]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return bytes;
}

/// Hash arbitrary data using Poseidon
pub fn hash(data: []const u8) Hash {
    return poseidon.hash(data);
}

/// Hash two 32-byte values
pub fn hash2(a: Hash, b: Hash) Hash {
    return poseidon.hash2(a, b);
}

// ============================================================================
// Common Types
// ============================================================================

/// Privacy pool denomination presets
pub const Denomination = struct {
    pub const SOL_0_1: u64 = 100_000_000; // 0.1 SOL
    pub const SOL_1: u64 = 1_000_000_000; // 1 SOL
    pub const SOL_10: u64 = 10_000_000_000; // 10 SOL
    pub const SOL_100: u64 = 100_000_000_000; // 100 SOL
    pub const USDC_10: u64 = 10_000_000; // 10 USDC (6 decimals)
    pub const USDC_100: u64 = 100_000_000; // 100 USDC
    pub const USDC_1000: u64 = 1_000_000_000; // 1000 USDC
};

/// Error types
pub const Error = error{
    InvalidProof,
    InvalidMerkleRoot,
    InvalidCommitment,
    NullifierAlreadySpent,
    InsufficientBalance,
    ValueOutOfRange,
    TreeFull,
    IndexOutOfBounds,
};

// ============================================================================
// High-level API
// ============================================================================

/// Create a new privacy deposit
pub fn createDeposit(amount: u64) transfer.DepositNote {
    return transfer.DepositNote.generate(amount);
}

/// Create a new stealth wallet
pub fn createStealthWallet() stealth.StealthWallet {
    return stealth.StealthWallet.generate();
}

/// Generate a stealth address for a recipient
pub fn generateStealthAddress(meta: stealth.StealthMetaAddress) stealth.StealthAddressResult {
    return stealth.generateStealthAddress(meta);
}

/// Create a new nullifier
pub fn createNullifier() nullifier.Nullifier {
    return nullifier.Nullifier.generate();
}

/// Create a Merkle tree for deposits
pub fn createMerkleTree(allocator: std.mem.Allocator) !merkle.Tree20 {
    return merkle.Tree20.init(allocator);
}

/// Create a smaller Merkle tree for testing
pub fn createSmallMerkleTree(allocator: std.mem.Allocator) !merkle.Tree10 {
    return merkle.Tree10.init(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "privacy: full deposit and withdraw flow" {
    const allocator = std.testing.allocator;

    // 1. Create merkle tree
    var tree = try createSmallMerkleTree(allocator);
    defer tree.deinit();

    // 2. Generate deposit
    const deposit_amount: u64 = Denomination.SOL_1;
    var note = createDeposit(deposit_amount);

    // 3. Insert into tree
    note.leaf_index = try tree.insert(note.commitment);
    try std.testing.expectEqual(@as(u64, 0), note.leaf_index.?);

    // 4. Get merkle proof
    var proof = try tree.getProof(allocator, note.leaf_index.?);
    defer {
        allocator.free(proof.path);
        allocator.free(proof.indices);
    }

    // 5. Verify proof
    try std.testing.expect(proof.verify(tree.getRoot(), note.commitment));

    // 6. Generate withdraw proof inputs
    const recipient: Hash = [_]u8{0xAB} ** 32;
    const withdraw_input = transfer.WithdrawInput{
        .note = note,
        .merkle_proof = proof,
        .merkle_root = tree.getRoot(),
        .recipient = recipient,
        .relayer = null,
        .relayer_fee = 0,
    };

    // 7. Generate withdraw proof
    const withdraw_proof = try transfer.generateWithdrawProof(withdraw_input);
    try std.testing.expectEqual(deposit_amount, withdraw_proof.amount);
}

test "privacy: stealth address flow" {
    // Use deterministic keys for testing
    const view_private: [32]u8 = [_]u8{1} ** 32;
    const spend_private: [32]u8 = [_]u8{2} ** 32;
    const ephemeral_private: [32]u8 = [_]u8{3} ** 32;

    const wallet = stealth.StealthWallet{
        .view_keypair = stealth.Keypair.fromPrivate(view_private),
        .spend_keypair = stealth.Keypair.fromPrivate(spend_private),
    };
    const meta = wallet.getMetaAddress();

    // Sender generates stealth address with known ephemeral
    const result = stealth.generateStealthAddressWithEphemeral(meta, ephemeral_private);

    // Recipient scans
    const scanned = wallet.scan(result.ephemeral_pubkey).?;

    // Verify addresses match (deterministic)
    try std.testing.expectEqualSlices(u8, &result.stealth_address, &scanned.stealth_address);
}

test "privacy: nullifier management" {
    const allocator = std.testing.allocator;

    // Create nullifier set
    var set = nullifier.NullifierSet.init(allocator);
    defer set.deinit();

    // Generate and track nullifier
    const n = createNullifier();
    try std.testing.expect(!set.isSpent(n.hash));

    try set.markSpent(n.hash);
    try std.testing.expect(set.isSpent(n.hash));
}

test "privacy: hash functions" {
    const data = "hello privacy";
    const h1 = hash(data);
    const h2 = hash(data);
    try std.testing.expectEqualSlices(u8, &h1, &h2);

    const a: Hash = [_]u8{1} ** 32;
    const b: Hash = [_]u8{2} ** 32;
    const h3 = hash2(a, b);
    try std.testing.expect(!std.mem.eql(u8, &h3, &ZERO_HASH));
}

test {
    // Run all module tests
    _ = poseidon;
    _ = merkle;
    _ = pedersen;
    _ = stealth;
    _ = nullifier;
    _ = transfer;
    _ = zk;
    _ = confidential;
}
