//! Privacy SDK Use Cases - Complete Examples
//!
//! This file demonstrates the three main use cases:
//! 1. Private Donations - Hide donor identity
//! 2. Privacy Pool - Break transaction graph
//! 3. Confidential Payments - Hide payment amounts

const std = @import("std");
const privacy = @import("privacy_zig");

// ============================================================================
// Use Case 1: Private Donations
// ============================================================================
//
// Scenario: A charity wants to receive donations without revealing
// who donated or how much each person gave in total.
//
// Flow:
// 1. Charity creates a stealth wallet and publishes meta-address
// 2. Each donor generates a unique stealth address
// 3. Donors send funds to their generated stealth address
// 4. Charity scans the chain to find and collect donations
//

pub const PrivateDonations = struct {
    /// Charity side: Create wallet and publish meta-address
    pub fn charitySetup() !struct {
        wallet: privacy.stealth.StealthWallet,
        meta_address: privacy.stealth.StealthMetaAddress,
    } {
        // Charity generates a stealth wallet (keep private!)
        const wallet = privacy.stealth.StealthWallet.generate();
        
        // Charity publishes this meta-address on their website
        const meta_address = wallet.getMetaAddress();
        
        std.debug.print("=== Charity Setup ===\n", .{});
        std.debug.print("Meta Address (publish this):\n", .{});
        std.debug.print("  View Key:  {x}\n", .{meta_address.view_key});
        std.debug.print("  Spend Key: {x}\n", .{meta_address.spend_key});
        
        return .{
            .wallet = wallet,
            .meta_address = meta_address,
        };
    }
    
    /// Donor side: Generate one-time stealth address for donation
    pub fn donorGenerateAddress(charity_meta: privacy.stealth.StealthMetaAddress) !struct {
        stealth_address: [32]u8,
        ephemeral_pubkey: [32]u8,
    } {
        // Donor generates a unique stealth address
        const result = privacy.stealth.generateStealthAddress(charity_meta);
        
        std.debug.print("\n=== Donor: Generate Stealth Address ===\n", .{});
        std.debug.print("Stealth Address: {x}\n", .{result.stealth_address});
        std.debug.print("Ephemeral Pubkey: {x}\n", .{result.ephemeral_pubkey});
        std.debug.print("\nDonor should:\n", .{});
        std.debug.print("1. Send funds to stealth_address\n", .{});
        std.debug.print("2. Publish ephemeral_pubkey with the transaction\n", .{});
        
        return .{
            .stealth_address = result.stealth_address,
            .ephemeral_pubkey = result.ephemeral_pubkey,
        };
    }
    
    /// Charity side: Scan for incoming donations
    pub fn charityScan(
        wallet: *const privacy.stealth.StealthWallet,
        ephemeral_pubkeys: []const [32]u8,
    ) void {
        std.debug.print("\n=== Charity: Scanning for Donations ===\n", .{});
        
        for (ephemeral_pubkeys, 0..) |epk, i| {
            if (wallet.scan(epk)) |found| {
                std.debug.print("Found donation #{d}!\n", .{i + 1});
                std.debug.print("  Address: {x}\n", .{found.stealth_address});
                // Charity can now spend from this address
            }
        }
    }
};

// ============================================================================
// Use Case 2: Privacy Pool (Mixer)
// ============================================================================
//
// Scenario: Users want to break the link between their deposit and
// withdrawal addresses.
//
// Flow:
// 1. User creates a secret and nullifier, computes commitment
// 2. User deposits funds with commitment to the pool
// 3. Wait for others to deposit (larger anonymity set)
// 4. User withdraws to NEW address using ZK proof
// 5. The ZK proof proves they deposited, without revealing which deposit
//

pub const PrivacyPool = struct {
    /// User creates deposit note (keep secret and nullifier private!)
    pub fn createDepositNote(amount: u64) !struct {
        secret: [32]u8,
        nullifier: [32]u8,
        commitment: [32]u8,
        amount: u64,
    } {
        // Generate random secret and nullifier
        var secret: [32]u8 = undefined;
        var nullifier: [32]u8 = undefined;
        std.crypto.random.bytes(&secret);
        std.crypto.random.bytes(&nullifier);
        
        // Compute commitment = hash(secret, nullifier, amount)
        var amount_bytes: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u64, amount_bytes[24..32], amount, .big);
        
        const commitment = privacy.poseidon.hashMany(&[_][32]u8{
            secret,
            nullifier,
            amount_bytes,
        });
        
        std.debug.print("\n=== Create Deposit Note ===\n", .{});
        std.debug.print("Amount: {} lamports\n", .{amount});
        std.debug.print("Secret: {x} (KEEP PRIVATE!)\n", .{secret});
        std.debug.print("Nullifier: {x} (KEEP PRIVATE!)\n", .{nullifier});
        std.debug.print("Commitment: {x} (submit to pool)\n", .{commitment});
        
        return .{
            .secret = secret,
            .nullifier = nullifier,
            .commitment = commitment,
            .amount = amount,
        };
    }
    
    /// Simulate deposit to pool (on-chain this calls the deposit instruction)
    pub fn deposit(
        allocator: std.mem.Allocator,
        tree: *privacy.merkle.Tree20,
        commitment: [32]u8,
    ) !u64 {
        const leaf_index = try tree.insert(commitment);
        
        std.debug.print("\n=== Deposit to Pool ===\n", .{});
        std.debug.print("Commitment inserted at index: {}\n", .{leaf_index});
        std.debug.print("New Merkle root: {x}\n", .{tree.getRoot()});
        
        _ = allocator;
        return leaf_index;
    }
    
    /// Prepare withdrawal (generate proof inputs)
    pub fn prepareWithdrawal(
        allocator: std.mem.Allocator,
        tree: *privacy.merkle.Tree20,
        leaf_index: u64,
        secret: [32]u8,
        nullifier: [32]u8,
        recipient: [32]u8,
    ) !struct {
        root: [32]u8,
        nullifier_hash: [32]u8,
        proof_inputs: privacy.zk.WithdrawCircuitInput,
    } {
        // Get Merkle proof
        const proof = try tree.getProof(allocator, leaf_index);
        defer {
            allocator.free(proof.path);
            allocator.free(proof.indices);
        }
        
        // Compute nullifier hash (this is revealed on-chain to prevent double-spend)
        const nullifier_hash = privacy.poseidon.hash(&nullifier);
        
        const inputs = privacy.zk.buildWithdrawInput(
            secret,
            nullifier,
            proof,
            tree.getRoot(),
            recipient,
            [_]u8{0} ** 32, // relayer
            0, // fee
        );
        
        std.debug.print("\n=== Prepare Withdrawal ===\n", .{});
        std.debug.print("Recipient: {x}\n", .{recipient});
        std.debug.print("Merkle Root: {x}\n", .{tree.getRoot()});
        std.debug.print("Nullifier Hash: {x} (revealed on-chain)\n", .{nullifier_hash});
        std.debug.print("\nNext steps:\n", .{});
        std.debug.print("1. Generate ZK proof with these inputs (using circom/snarkjs)\n", .{});
        std.debug.print("2. Submit proof + nullifier_hash + recipient to withdraw instruction\n", .{});
        std.debug.print("3. Pool verifies proof and transfers funds to recipient\n", .{});
        
        return .{
            .root = tree.getRoot(),
            .nullifier_hash = nullifier_hash,
            .proof_inputs = inputs,
        };
    }
};

// ============================================================================
// Use Case 3: Confidential Payments
// ============================================================================
//
// Scenario: Alice wants to pay Bob, but hide the amount from observers.
//
// Flow:
// 1. Alice creates a Pedersen commitment to the amount
// 2. Alice encrypts (amount, blinding) for Bob's eyes only
// 3. Transaction shows only the commitment (not the amount)
// 4. Bob decrypts to learn the actual amount
//

pub const ConfidentialPayments = struct {
    /// Alice creates a confidential payment
    pub fn createPayment(amount: u64, recipient_pubkey: [32]u8) !struct {
        commitment: [32]u8,
        blinding: [32]u8,
        encrypted_note: [64]u8, // simplified: just XOR with shared secret
    } {
        // Generate random blinding factor
        const blinding = privacy.pedersen.randomBlinding();
        
        // Create Pedersen commitment: C = amount*G + blinding*H
        // Convert amount to scalar bytes
        var amount_scalar: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u64, amount_scalar[24..32], amount, .big);
        const commitment = privacy.pedersen.commit(amount_scalar, blinding);
        
        // In real implementation: use ECDH to derive shared secret,
        // then encrypt (amount, blinding) for recipient
        // Simplified here: just XOR with hash of recipient pubkey
        var encrypted_note: [64]u8 = undefined;
        const encryption_key = privacy.poseidon.hash(&recipient_pubkey);
        
        // Encrypt amount (8 bytes) and blinding (32 bytes)
        var amount_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &amount_bytes, amount, .little);
        
        for (0..8) |i| {
            encrypted_note[i] = amount_bytes[i] ^ encryption_key[i];
        }
        for (0..32) |i| {
            encrypted_note[8 + i] = blinding[i] ^ encryption_key[i % 32];
        }
        // Remaining bytes are padding
        @memset(encrypted_note[40..], 0);
        
        std.debug.print("\n=== Create Confidential Payment ===\n", .{});
        std.debug.print("Amount: {} (hidden)\n", .{amount});
        std.debug.print("Commitment: {x} (public)\n", .{commitment});
        std.debug.print("Encrypted Note: {x}... (only recipient can decrypt)\n", .{encrypted_note[0..16].*});
        
        return .{
            .commitment = commitment,
            .blinding = blinding,
            .encrypted_note = encrypted_note,
        };
    }
    
    /// Bob decrypts the payment
    pub fn decryptPayment(
        encrypted_note: [64]u8,
        commitment: [32]u8,
        my_secret_key: [32]u8, // In real impl: derive from ECDH
    ) !struct {
        amount: u64,
        valid: bool,
    } {
        // Derive decryption key (simplified)
        const decryption_key = privacy.poseidon.hash(&my_secret_key);
        
        // Decrypt amount
        var amount_bytes: [8]u8 = undefined;
        for (0..8) |i| {
            amount_bytes[i] = encrypted_note[i] ^ decryption_key[i];
        }
        const amount = std.mem.readInt(u64, &amount_bytes, .little);
        
        // Decrypt blinding
        var blinding: [32]u8 = undefined;
        for (0..32) |i| {
            blinding[i] = encrypted_note[8 + i] ^ decryption_key[i % 32];
        }
        
        // Verify commitment matches
        var amount_scalar: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u64, amount_scalar[24..32], amount, .big);
        const expected_commitment = privacy.pedersen.commit(amount_scalar, blinding);
        const valid = std.mem.eql(u8, &commitment, &expected_commitment);
        
        std.debug.print("\n=== Decrypt Confidential Payment ===\n", .{});
        std.debug.print("Decrypted Amount: {}\n", .{amount});
        std.debug.print("Commitment Valid: {}\n", .{valid});
        
        return .{
            .amount = amount,
            .valid = valid,
        };
    }
};

// ============================================================================
// Demo: Run all use cases
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n{'='**60}\n", .{});
    std.debug.print("Privacy SDK Use Cases Demo\n", .{});
    std.debug.print("{'='**60}\n", .{});
    
    // ===== Use Case 1: Private Donations =====
    std.debug.print("\n\n>>> USE CASE 1: PRIVATE DONATIONS <<<\n", .{});
    
    const charity = try PrivateDonations.charitySetup();
    
    // Multiple donors send to unique addresses
    const donor1 = try PrivateDonations.donorGenerateAddress(charity.meta_address);
    const donor2 = try PrivateDonations.donorGenerateAddress(charity.meta_address);
    
    // Charity scans and finds donations
    const epks = [_][32]u8{ donor1.ephemeral_pubkey, donor2.ephemeral_pubkey };
    PrivateDonations.charityScan(&charity.wallet, &epks);
    
    // ===== Use Case 2: Privacy Pool =====
    std.debug.print("\n\n>>> USE CASE 2: PRIVACY POOL (MIXER) <<<\n", .{});
    
    var tree = try privacy.merkle.Tree20.init(allocator);
    defer tree.deinit();
    
    // Alice deposits
    const alice_note = try PrivacyPool.createDepositNote(1_000_000_000); // 1 SOL
    const alice_index = try PrivacyPool.deposit(allocator, &tree, alice_note.commitment);
    
    // Bob also deposits (increases anonymity set)
    const bob_note = try PrivacyPool.createDepositNote(1_000_000_000);
    _ = try PrivacyPool.deposit(allocator, &tree, bob_note.commitment);
    
    // Alice withdraws to NEW address
    var new_address: [32]u8 = undefined;
    std.crypto.random.bytes(&new_address);
    
    _ = try PrivacyPool.prepareWithdrawal(
        allocator,
        &tree,
        alice_index,
        alice_note.secret,
        alice_note.nullifier,
        new_address,
    );
    
    // ===== Use Case 3: Confidential Payments =====
    std.debug.print("\n\n>>> USE CASE 3: CONFIDENTIAL PAYMENTS <<<\n", .{});
    
    // Bob's public key (simplified)
    var bob_pubkey: [32]u8 = undefined;
    std.crypto.random.bytes(&bob_pubkey);
    
    // Alice pays Bob 500 tokens confidentially
    const payment = try ConfidentialPayments.createPayment(500, bob_pubkey);
    
    // Bob decrypts (using pubkey as secret for demo)
    _ = try ConfidentialPayments.decryptPayment(
        payment.encrypted_note,
        payment.commitment,
        bob_pubkey,
    );
    
    std.debug.print("\n\n{'='**60}\n", .{});
    std.debug.print("Demo Complete!\n", .{});
    std.debug.print("{'='**60}\n\n", .{});
}

// ============================================================================
// Tests
// ============================================================================

test "use case 1: private donations" {
    const charity = try PrivateDonations.charitySetup();
    const donor = try PrivateDonations.donorGenerateAddress(charity.meta_address);
    
    // Charity should be able to find the donation
    if (charity.wallet.scan(donor.ephemeral_pubkey)) |found| {
        try std.testing.expectEqualSlices(u8, &donor.stealth_address, &found.stealth_address);
    } else {
        return error.DonationNotFound;
    }
}

test "use case 2: privacy pool" {
    const allocator = std.testing.allocator;
    
    var tree = try privacy.merkle.Tree20.init(allocator);
    defer tree.deinit();
    
    const note = try PrivacyPool.createDepositNote(1_000_000_000);
    const index = try PrivacyPool.deposit(allocator, &tree, note.commitment);
    
    var recipient: [32]u8 = undefined;
    std.crypto.random.bytes(&recipient);
    
    const withdrawal = try PrivacyPool.prepareWithdrawal(
        allocator,
        &tree,
        index,
        note.secret,
        note.nullifier,
        recipient,
    );
    
    // Verify nullifier hash is derived correctly
    const expected_nullifier_hash = privacy.poseidon.hash(&note.nullifier);
    try std.testing.expectEqualSlices(u8, &expected_nullifier_hash, &withdrawal.nullifier_hash);
}

test "use case 3: confidential payments" {
    var recipient_key: [32]u8 = undefined;
    std.crypto.random.bytes(&recipient_key);
    
    const payment = try ConfidentialPayments.createPayment(12345, recipient_key);
    const decrypted = try ConfidentialPayments.decryptPayment(
        payment.encrypted_note,
        payment.commitment,
        recipient_key,
    );
    
    try std.testing.expectEqual(@as(u64, 12345), decrypted.amount);
    try std.testing.expect(decrypted.valid);
}
