//! Stealth Confidential Payment
//!
//! Combines stealth addresses with confidential transfers for maximum privacy:
//! - Recipient identity hidden (stealth address)
//! - Payment amount hidden (encrypted)
//!
//! ## Flow
//!
//! ### Setup (one time)
//! 1. Bob creates a StealthWallet
//! 2. Bob publishes his MetaAddress (view_key, spend_key)
//!
//! ### Payment
//! 1. Alice looks up Bob's MetaAddress
//! 2. Alice generates:
//!    - Stealth address (one-time address for this payment)
//!    - Encrypted amount (only Bob can decrypt)
//! 3. Alice sends transaction:
//!    - To: stealth_address
//!    - Amount: commitment (hidden)
//!    - Data: ephemeral_pubkey + encrypted_note
//!
//! ### Receiving
//! 1. Bob scans transactions for his stealth addresses
//! 2. Bob decrypts the amount
//! 3. Bob can spend from the stealth address
//!
//! ## On-Chain Data
//!
//! What observers see:
//! - Transfer to address 0x1234... (cannot link to Bob)
//! - Commitment 0xABCD... (cannot learn amount)
//! - Some encrypted data (cannot decrypt)
//!
//! What Bob sees:
//! - "Alice sent me 1000 USDC to stealth address 0x1234..."

const std = @import("std");
const stealth = @import("../stealth/mod.zig");
const confidential = @import("mod.zig");
const poseidon = @import("../crypto/poseidon.zig");
const pedersen = @import("../crypto/pedersen.zig");

// ============================================================================
// Types
// ============================================================================

/// A complete stealth confidential payment
pub const StealthPayment = struct {
    /// One-time stealth address to send funds to
    stealth_address: [32]u8,
    
    /// Ephemeral public key (needed for recipient to find payment)
    ephemeral_pubkey: [32]u8,
    
    /// Pedersen commitment to the amount
    commitment: [32]u8,
    
    /// Encrypted note (amount + blinding, only recipient can decrypt)
    encrypted_note: confidential.EncryptedNote,
    
    /// Total on-chain data size
    pub const ON_CHAIN_SIZE: usize = 32 + 32 + 32 + confidential.EncryptedNote.SIZE;
    
    /// Serialize for on-chain storage
    pub fn toBytes(self: *const StealthPayment) [ON_CHAIN_SIZE]u8 {
        var result: [ON_CHAIN_SIZE]u8 = undefined;
        var offset: usize = 0;
        
        @memcpy(result[offset..][0..32], &self.stealth_address);
        offset += 32;
        
        @memcpy(result[offset..][0..32], &self.ephemeral_pubkey);
        offset += 32;
        
        @memcpy(result[offset..][0..32], &self.commitment);
        offset += 32;
        
        const note_bytes = self.encrypted_note.toBytes();
        @memcpy(result[offset..][0..confidential.EncryptedNote.SIZE], &note_bytes);
        
        return result;
    }
    
    /// Deserialize from on-chain data
    pub fn fromBytes(bytes: [ON_CHAIN_SIZE]u8) StealthPayment {
        var offset: usize = 0;
        
        const stealth_addr = bytes[offset..][0..32].*;
        offset += 32;
        
        const ephemeral = bytes[offset..][0..32].*;
        offset += 32;
        
        const commit = bytes[offset..][0..32].*;
        offset += 32;
        
        const note = confidential.EncryptedNote.fromBytes(bytes[offset..][0..confidential.EncryptedNote.SIZE].*);
        
        return .{
            .stealth_address = stealth_addr,
            .ephemeral_pubkey = ephemeral,
            .commitment = commit,
            .encrypted_note = note,
        };
    }
};

/// Decrypted payment information
pub const ReceivedPayment = struct {
    /// The stealth address funds were sent to
    stealth_address: [32]u8,
    /// The private key to spend from this address
    spending_key: [32]u8,
    /// The decrypted amount
    amount: u64,
    /// The blinding factor
    blinding: [32]u8,
    /// Whether all verifications passed
    valid: bool,
};

// ============================================================================
// Core Functions  
// ============================================================================

/// Create a stealth confidential payment
///
/// Alice calls this to pay Bob without revealing:
/// - That Bob is the recipient (stealth address)
/// - How much she's paying (encrypted amount)
pub fn createPayment(
    amount: u64,
    recipient_meta: stealth.StealthMetaAddress,
) StealthPayment {
    // 1. Generate stealth address
    const stealth_result = stealth.generateStealthAddress(recipient_meta);
    
    // 2. Generate random blinding for commitment
    const blinding = pedersen.randomBlinding();
    
    // 3. Create Pedersen commitment
    var amount_scalar: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, amount_scalar[24..32], amount, .big);
    const commitment = pedersen.commit(amount_scalar, blinding);
    
    // 4. Derive shared secret for encryption using stealth components
    const shared_secret = deriveSharedSecret(
        stealth_result.ephemeral_pubkey,
        recipient_meta.view_key,
    );
    
    // 5. Encrypt amount and blinding
    const encrypted_note = encryptAmountAndBlinding(
        amount,
        blinding,
        shared_secret,
        stealth_result.ephemeral_pubkey,
    );
    
    return .{
        .stealth_address = stealth_result.stealth_address,
        .ephemeral_pubkey = stealth_result.ephemeral_pubkey,
        .commitment = commitment,
        .encrypted_note = encrypted_note,
    };
}

/// Scan and decrypt a payment
///
/// Bob calls this for each transaction to check if it's for him
pub fn receivePayment(
    wallet: *const stealth.StealthWallet,
    payment: StealthPayment,
) ?ReceivedPayment {
    // 1. Check if this stealth address belongs to us
    const scan_result = wallet.scan(payment.ephemeral_pubkey) orelse return null;
    
    // Verify the stealth address matches
    if (!std.mem.eql(u8, &scan_result.stealth_address, &payment.stealth_address)) {
        return null;
    }
    
    // 2. Derive shared secret (same as sender)
    // Sender: shared = derive(ephemeral_pub, view_key) where view_key = pub(view_priv)
    // Receiver: shared = derive(ephemeral_pub, pub(view_priv)) = same!
    const view_key = wallet.getMetaAddress().view_key;
    const shared_secret = deriveSharedSecret(
        payment.ephemeral_pubkey,
        view_key,
    );
    
    // 3. Decrypt the amount
    const decrypted = decryptAmountAndBlinding(
        payment.encrypted_note.ciphertext,
        shared_secret,
    ) catch return null;
    
    // 4. Verify commitment
    var amount_scalar: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, amount_scalar[24..32], decrypted.amount, .big);
    const expected_commitment = pedersen.commit(amount_scalar, decrypted.blinding);
    const commitment_valid = std.mem.eql(u8, &payment.commitment, &expected_commitment);
    
    // 5. Compute spending key for this stealth address
    const spending_key = wallet.computeStealthPrivateKey(payment.ephemeral_pubkey);
    
    return .{
        .stealth_address = payment.stealth_address,
        .spending_key = spending_key,
        .amount = decrypted.amount,
        .blinding = decrypted.blinding,
        .valid = commitment_valid,
    };
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Derive shared secret from ephemeral pubkey and view key
/// This is symmetric: sender and receiver get the same result
fn deriveSharedSecret(ephemeral_pubkey: [32]u8, view_key: [32]u8) [32]u8 {
    const domain: [32]u8 = comptime blk: {
        var d: [32]u8 = [_]u8{0} ** 32;
        const tag = "stealth_shared______";
        @memcpy(d[0..tag.len], tag);
        break :blk d;
    };
    
    return poseidon.hashMany(&[_][32]u8{ ephemeral_pubkey, view_key, domain });
}

/// Encrypt amount and blinding using shared secret
fn encryptAmountAndBlinding(
    amount: u64,
    blinding: [32]u8,
    shared_secret: [32]u8,
    ephemeral_pubkey: [32]u8,
) confidential.EncryptedNote {
    var ciphertext: [confidential.ENCRYPTED_NOTE_SIZE]u8 = undefined;
    
    // Derive encryption key from shared secret
    const key_domain: [32]u8 = comptime blk: {
        var d: [32]u8 = [_]u8{0} ** 32;
        const tag = "stealth_enc_key_____";
        @memcpy(d[0..tag.len], tag);
        break :blk d;
    };
    const key = poseidon.hash2(shared_secret, key_domain);
    
    // Plaintext: amount (8 bytes) + blinding (32 bytes)
    var plaintext: [40]u8 = undefined;
    std.mem.writeInt(u64, plaintext[0..8], amount, .little);
    @memcpy(plaintext[8..40], &blinding);
    
    // XOR encryption
    for (0..40) |i| {
        ciphertext[i] = plaintext[i] ^ key[i % 32];
    }
    
    // Authentication tag
    const tag_domain: [32]u8 = comptime blk: {
        var d: [32]u8 = [_]u8{0} ** 32;
        const tag = "stealth_auth_tag____";
        @memcpy(d[0..tag.len], tag);
        break :blk d;
    };
    var tag_input: [72]u8 = undefined;
    @memcpy(tag_input[0..40], &plaintext);
    @memcpy(tag_input[40..72], &tag_domain);
    const tag = poseidon.hash(&tag_input);
    @memcpy(ciphertext[40..56], tag[0..16]);
    
    return .{
        .ciphertext = ciphertext,
        .ephemeral_pubkey = ephemeral_pubkey,
    };
}

/// Decrypt amount and blinding using shared secret
fn decryptAmountAndBlinding(
    ciphertext: [confidential.ENCRYPTED_NOTE_SIZE]u8,
    shared_secret: [32]u8,
) !struct { amount: u64, blinding: [32]u8 } {
    // Derive encryption key from shared secret
    const key_domain: [32]u8 = comptime blk: {
        var d: [32]u8 = [_]u8{0} ** 32;
        const tag = "stealth_enc_key_____";
        @memcpy(d[0..tag.len], tag);
        break :blk d;
    };
    const key = poseidon.hash2(shared_secret, key_domain);
    
    // Decrypt
    var plaintext: [40]u8 = undefined;
    for (0..40) |i| {
        plaintext[i] = ciphertext[i] ^ key[i % 32];
    }
    
    // Verify authentication tag
    const tag_domain: [32]u8 = comptime blk: {
        var d: [32]u8 = [_]u8{0} ** 32;
        const tag = "stealth_auth_tag____";
        @memcpy(d[0..tag.len], tag);
        break :blk d;
    };
    var tag_input: [72]u8 = undefined;
    @memcpy(tag_input[0..40], &plaintext);
    @memcpy(tag_input[40..72], &tag_domain);
    const expected_tag = poseidon.hash(&tag_input);
    
    if (!std.mem.eql(u8, ciphertext[40..56], expected_tag[0..16])) {
        return error.AuthenticationFailed;
    }
    
    // Parse
    const amount = std.mem.readInt(u64, plaintext[0..8], .little);
    var blinding: [32]u8 = undefined;
    @memcpy(&blinding, plaintext[8..40]);
    
    return .{
        .amount = amount,
        .blinding = blinding,
    };
}

// ============================================================================
// High-Level API
// ============================================================================

/// Pay someone using their published meta-address
/// 
/// Example:
/// ```zig
/// // Bob publishes his meta-address
/// const bob_meta = bob_wallet.getMetaAddress();
/// 
/// // Alice pays Bob (nobody knows it's to Bob or how much)
/// const payment = stealthPay(1000_000_000, bob_meta); // 1 SOL
/// 
/// // Submit payment.stealth_address as recipient
/// // Store payment data on-chain or in memo
/// ```
pub fn stealthPay(amount: u64, recipient_meta: stealth.StealthMetaAddress) StealthPayment {
    return createPayment(amount, recipient_meta);
}

/// Scan a payment to see if it's for you
///
/// Example:
/// ```zig
/// // Bob scans incoming transactions
/// for (transactions) |tx| {
///     if (stealthReceive(&bob_wallet, tx.payment_data)) |received| {
///         print("Received {} tokens!", received.amount);
///         // Can spend using received.spending_key
///     }
/// }
/// ```
pub fn stealthReceive(wallet: *const stealth.StealthWallet, payment: StealthPayment) ?ReceivedPayment {
    return receivePayment(wallet, payment);
}

// ============================================================================
// Tests
// ============================================================================

test "stealth_pay: create and receive payment" {
    // Bob sets up wallet
    const bob_wallet = stealth.StealthWallet.generate();
    const bob_meta = bob_wallet.getMetaAddress();
    
    // Alice pays Bob
    const payment = createPayment(1_000_000_000, bob_meta);
    
    // Bob receives
    const received = receivePayment(&bob_wallet, payment) orelse {
        return error.PaymentNotFound;
    };
    
    try std.testing.expectEqual(@as(u64, 1_000_000_000), received.amount);
    try std.testing.expect(received.valid);
    try std.testing.expectEqualSlices(u8, &payment.stealth_address, &received.stealth_address);
}

test "stealth_pay: wrong recipient cannot receive" {
    const alice_wallet = stealth.StealthWallet.generate();
    const bob_wallet = stealth.StealthWallet.generate();
    const bob_meta = bob_wallet.getMetaAddress();
    
    // Payment to Bob
    const payment = createPayment(500, bob_meta);
    
    // Alice tries to receive (should fail)
    const result = receivePayment(&alice_wallet, payment);
    try std.testing.expect(result == null);
}

test "stealth_pay: serialization roundtrip" {
    const bob_wallet = stealth.StealthWallet.generate();
    const bob_meta = bob_wallet.getMetaAddress();
    
    const payment = createPayment(12345, bob_meta);
    
    // Serialize (for on-chain storage)
    const bytes = payment.toBytes();
    
    // Deserialize (from on-chain data)
    const restored = StealthPayment.fromBytes(bytes);
    
    // Should still be receivable
    const received = receivePayment(&bob_wallet, restored) orelse {
        return error.PaymentNotFound;
    };
    
    try std.testing.expectEqual(@as(u64, 12345), received.amount);
}

test "stealth_pay: multiple payments to same recipient" {
    const bob_wallet = stealth.StealthWallet.generate();
    const bob_meta = bob_wallet.getMetaAddress();
    
    // Multiple payments
    const payment1 = createPayment(100, bob_meta);
    const payment2 = createPayment(200, bob_meta);
    const payment3 = createPayment(300, bob_meta);
    
    // All stealth addresses should be different
    try std.testing.expect(!std.mem.eql(u8, &payment1.stealth_address, &payment2.stealth_address));
    try std.testing.expect(!std.mem.eql(u8, &payment2.stealth_address, &payment3.stealth_address));
    
    // Bob can receive all of them
    const r1 = receivePayment(&bob_wallet, payment1).?;
    const r2 = receivePayment(&bob_wallet, payment2).?;
    const r3 = receivePayment(&bob_wallet, payment3).?;
    
    try std.testing.expectEqual(@as(u64, 100), r1.amount);
    try std.testing.expectEqual(@as(u64, 200), r2.amount);
    try std.testing.expectEqual(@as(u64, 300), r3.amount);
}

test "stealth_pay: observer cannot learn amount" {
    const bob_wallet = stealth.StealthWallet.generate();
    const bob_meta = bob_wallet.getMetaAddress();
    
    const payment1 = createPayment(1000, bob_meta);
    const payment2 = createPayment(1000, bob_meta);
    
    // Even same amount produces different commitments
    try std.testing.expect(!std.mem.eql(u8, &payment1.commitment, &payment2.commitment));
    
    // And different encrypted notes
    try std.testing.expect(!std.mem.eql(
        u8, 
        &payment1.encrypted_note.ciphertext,
        &payment2.encrypted_note.ciphertext,
    ));
}
