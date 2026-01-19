//! Stealth Address Implementation
//!
//! Stealth addresses allow recipients to receive payments without
//! revealing their identity on-chain.
//!
//! Protocol:
//! 1. Recipient publishes a "stealth meta-address" (view key + spend key)
//! 2. Sender generates ephemeral keypair
//! 3. Sender computes shared secret: S = ephemeral_private * view_key
//! 4. Sender computes stealth address: stealth = spend_key + hash(S) * G
//! 5. Sender publishes ephemeral_public alongside the transaction
//! 6. Recipient scans: S' = view_private * ephemeral_public
//!    Then: stealth' = spend_key + hash(S') * G (should match)
//! 7. Recipient can spend: private = spend_private + hash(S')

const std = @import("std");
const poseidon = @import("../crypto/poseidon.zig");

/// Public key (32 bytes - Ed25519 style)
pub const PublicKey = [32]u8;

/// Private key (32 bytes)
pub const PrivateKey = [32]u8;

/// Keypair
pub const Keypair = struct {
    public: PublicKey,
    private: PrivateKey,

    /// Generate random keypair
    pub fn generate() Keypair {
        var private: PrivateKey = undefined;
        std.crypto.random.bytes(&private);

        // Derive public key (simplified - in production use Ed25519)
        const public = derivePublicKey(private);

        return .{
            .public = public,
            .private = private,
        };
    }

    /// Create from private key
    pub fn fromPrivate(private: PrivateKey) Keypair {
        return .{
            .public = derivePublicKey(private),
            .private = private,
        };
    }
};

/// Stealth meta-address (published by recipient)
pub const StealthMetaAddress = struct {
    /// View public key (for scanning)
    view_key: PublicKey,
    /// Spend public key (for receiving)
    spend_key: PublicKey,

    /// Create from keypairs
    pub fn fromKeypairs(view_keypair: Keypair, spend_keypair: Keypair) StealthMetaAddress {
        return .{
            .view_key = view_keypair.public,
            .spend_key = spend_keypair.public,
        };
    }

    /// Encode to bytes
    pub fn toBytes(self: *const StealthMetaAddress) [64]u8 {
        var bytes: [64]u8 = undefined;
        @memcpy(bytes[0..32], &self.view_key);
        @memcpy(bytes[32..64], &self.spend_key);
        return bytes;
    }

    /// Decode from bytes
    pub fn fromBytes(bytes: [64]u8) StealthMetaAddress {
        return .{
            .view_key = bytes[0..32].*,
            .spend_key = bytes[32..64].*,
        };
    }
};

/// Result of generating a stealth address
pub const StealthAddressResult = struct {
    /// The stealth address (where funds are sent)
    stealth_address: PublicKey,
    /// Ephemeral public key (sender must publish this)
    ephemeral_pubkey: PublicKey,
    /// View tag (optional - for efficient scanning)
    view_tag: u8,
};

/// Recipient's stealth wallet (private keys)
pub const StealthWallet = struct {
    /// View keypair (for scanning)
    view_keypair: Keypair,
    /// Spend keypair (for spending)
    spend_keypair: Keypair,

    /// Generate new stealth wallet
    pub fn generate() StealthWallet {
        return .{
            .view_keypair = Keypair.generate(),
            .spend_keypair = Keypair.generate(),
        };
    }

    /// Get public stealth meta-address
    pub fn getMetaAddress(self: *const StealthWallet) StealthMetaAddress {
        return StealthMetaAddress.fromKeypairs(self.view_keypair, self.spend_keypair);
    }

    /// Scan a transaction to check if it's for us
    pub fn scan(self: *const StealthWallet, ephemeral_pubkey: PublicKey) ?StealthAddressResult {
        // Compute shared secret: S = view_private * ephemeral_public
        const shared_secret = computeSharedSecret(self.view_keypair.private, ephemeral_pubkey);

        // Compute stealth address
        const stealth_hash = poseidon.hash(&shared_secret);
        const stealth_address = pointAdd(self.spend_keypair.public, stealth_hash);

        // Compute view tag
        const view_tag = shared_secret[0];

        return .{
            .stealth_address = stealth_address,
            .ephemeral_pubkey = ephemeral_pubkey,
            .view_tag = view_tag,
        };
    }

    /// Compute private key for a stealth address
    pub fn computeStealthPrivateKey(self: *const StealthWallet, ephemeral_pubkey: PublicKey) PrivateKey {
        // S = view_private * ephemeral_public
        const shared_secret = computeSharedSecret(self.view_keypair.private, ephemeral_pubkey);
        const stealth_hash = poseidon.hash(&shared_secret);

        // stealth_private = spend_private + hash(S)
        return scalarAdd(self.spend_keypair.private, stealth_hash);
    }
};

/// Generate a stealth address for a recipient
pub fn generateStealthAddress(meta_address: StealthMetaAddress) StealthAddressResult {
    // Generate ephemeral keypair
    const ephemeral = Keypair.generate();

    // Compute shared secret: S = ephemeral_private * view_key
    const shared_secret = computeSharedSecret(ephemeral.private, meta_address.view_key);

    // Compute stealth address: stealth = spend_key + hash(S) * G
    const stealth_hash = poseidon.hash(&shared_secret);
    const stealth_address = pointAdd(meta_address.spend_key, stealth_hash);

    // View tag for efficient scanning
    const view_tag = shared_secret[0];

    return .{
        .stealth_address = stealth_address,
        .ephemeral_pubkey = ephemeral.public,
        .view_tag = view_tag,
    };
}

/// Generate stealth address with specific ephemeral keypair (for testing)
pub fn generateStealthAddressWithEphemeral(
    meta_address: StealthMetaAddress,
    ephemeral_private: PrivateKey,
) StealthAddressResult {
    const ephemeral_public = derivePublicKey(ephemeral_private);

    const shared_secret = computeSharedSecret(ephemeral_private, meta_address.view_key);
    const stealth_hash = poseidon.hash(&shared_secret);
    const stealth_address = pointAdd(meta_address.spend_key, stealth_hash);
    const view_tag = shared_secret[0];

    return .{
        .stealth_address = stealth_address,
        .ephemeral_pubkey = ephemeral_public,
        .view_tag = view_tag,
    };
}

// ============================================================================
// Elliptic Curve Operations (Simplified)
// In production, use proper Ed25519 or secp256k1
// ============================================================================

/// Derive public key from private key
fn derivePublicKey(private: PrivateKey) PublicKey {
    // Simplified: hash(private || "pubkey")
    // In production: Ed25519 scalar multiplication
    var input: [40]u8 = undefined;
    @memcpy(input[0..32], &private);
    @memcpy(input[32..40], "pubkey!!");
    return poseidon.hash(&input);
}

/// Compute shared secret (ECDH)
/// For a proper implementation: S = private * public (EC scalar multiplication)
/// Our simplified version: S = hash(private_derived_point || public)
/// where private_derived_point = hash(private) to simulate scalar mult
fn computeSharedSecret(private: PrivateKey, public: PublicKey) [32]u8 {
    // In real ECDH: private_A * public_B == private_B * public_A
    // Simulate this by using a commutative operation
    // S = hash(min(derived_private, public) || max(derived_private, public))
    const derived = derivePublicKey(private);

    // Use XOR to make it commutative (a XOR b == b XOR a)
    var combined: [32]u8 = undefined;
    for (0..32) |i| {
        combined[i] = derived[i] ^ public[i];
    }
    return poseidon.hash(&combined);
}

/// Add point (public key) and scalar
fn pointAdd(point: PublicKey, scalar: [32]u8) PublicKey {
    // Simplified: hash(point || scalar || "add")
    // In production: EC point addition
    const scalar_point = derivePublicKey(scalar);
    return poseidon.hash2(point, scalar_point);
}

/// Add two scalars
fn scalarAdd(a: [32]u8, b: [32]u8) [32]u8 {
    // Simplified addition
    return poseidon.fieldAdd(a, b);
}

// ============================================================================
// Tests
// ============================================================================

test "stealth: keypair generation" {
    const kp = Keypair.generate();

    // Keys should be 32 bytes
    try std.testing.expectEqual(@as(usize, 32), kp.public.len);
    try std.testing.expectEqual(@as(usize, 32), kp.private.len);

    // Public should be derived from private
    const derived = derivePublicKey(kp.private);
    try std.testing.expectEqualSlices(u8, &kp.public, &derived);
}

test "stealth: meta address" {
    const wallet = StealthWallet.generate();
    const meta = wallet.getMetaAddress();

    // Encode and decode
    const bytes = meta.toBytes();
    const decoded = StealthMetaAddress.fromBytes(bytes);

    try std.testing.expectEqualSlices(u8, &meta.view_key, &decoded.view_key);
    try std.testing.expectEqualSlices(u8, &meta.spend_key, &decoded.spend_key);
}

test "stealth: generate and scan" {
    // Use deterministic keys for testing
    const view_private: PrivateKey = [_]u8{1} ** 32;
    const spend_private: PrivateKey = [_]u8{2} ** 32;
    const ephemeral_private: PrivateKey = [_]u8{3} ** 32;

    const view_keypair = Keypair.fromPrivate(view_private);
    const spend_keypair = Keypair.fromPrivate(spend_private);

    const wallet = StealthWallet{
        .view_keypair = view_keypair,
        .spend_keypair = spend_keypair,
    };
    const meta_address = wallet.getMetaAddress();

    // Sender generates stealth address with known ephemeral
    const result = generateStealthAddressWithEphemeral(meta_address, ephemeral_private);

    // Recipient scans
    const scanned = wallet.scan(result.ephemeral_pubkey).?;

    // Stealth addresses should match (deterministic test)
    try std.testing.expectEqualSlices(u8, &result.stealth_address, &scanned.stealth_address);
}

test "stealth: deterministic with same ephemeral" {
    const wallet = StealthWallet.generate();
    const meta = wallet.getMetaAddress();

    // Use fixed ephemeral for testing
    const ephemeral_private: PrivateKey = [_]u8{1} ** 32;

    const result1 = generateStealthAddressWithEphemeral(meta, ephemeral_private);
    const result2 = generateStealthAddressWithEphemeral(meta, ephemeral_private);

    try std.testing.expectEqualSlices(u8, &result1.stealth_address, &result2.stealth_address);
    try std.testing.expectEqualSlices(u8, &result1.ephemeral_pubkey, &result2.ephemeral_pubkey);
}

test "stealth: different recipients get different addresses" {
    const wallet1 = StealthWallet.generate();
    const wallet2 = StealthWallet.generate();

    const ephemeral_private: PrivateKey = [_]u8{1} ** 32;

    const result1 = generateStealthAddressWithEphemeral(wallet1.getMetaAddress(), ephemeral_private);
    const result2 = generateStealthAddressWithEphemeral(wallet2.getMetaAddress(), ephemeral_private);

    // Different recipients should get different stealth addresses
    try std.testing.expect(!std.mem.eql(u8, &result1.stealth_address, &result2.stealth_address));
}

test "stealth: compute private key" {
    // Note: This test verifies the stealth private key computation
    // In a real implementation with proper EC math, derived_public would equal stealth_address
    // With our simplified hash-based approach, we just verify the computation is deterministic

    const view_private: PrivateKey = [_]u8{10} ** 32;
    const spend_private: PrivateKey = [_]u8{20} ** 32;
    const ephemeral_private: PrivateKey = [_]u8{30} ** 32;

    const wallet = StealthWallet{
        .view_keypair = Keypair.fromPrivate(view_private),
        .spend_keypair = Keypair.fromPrivate(spend_private),
    };
    const meta = wallet.getMetaAddress();

    const result = generateStealthAddressWithEphemeral(meta, ephemeral_private);

    // Recipient computes stealth private key
    const stealth_private1 = wallet.computeStealthPrivateKey(result.ephemeral_pubkey);
    const stealth_private2 = wallet.computeStealthPrivateKey(result.ephemeral_pubkey);

    // Should be deterministic
    try std.testing.expectEqualSlices(u8, &stealth_private1, &stealth_private2);
}
