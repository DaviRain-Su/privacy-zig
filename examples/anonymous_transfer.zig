//! Anonymous Transfer Example
//!
//! Shows how to use Privacy Pool to anonymously transfer tokens to a new address.
//!
//! ## The Problem
//! Normal transfer: Alice → Bob (visible on chain)
//! Everyone knows Alice sent money to Bob.
//!
//! ## The Solution
//! 1. Alice deposits to Privacy Pool
//! 2. Alice generates ZK proof (off-chain)
//! 3. Anyone (relayer) submits withdraw to Bob's address
//! 4. Bob receives funds with NO link to Alice
//!
//! ## Privacy Properties
//! - Alice's deposit looks like any other deposit
//! - Bob's withdrawal could come from ANY depositor
//! - Only Alice knows the secret linking deposit → withdrawal

const std = @import("std");
const privacy_zig = @import("privacy_zig");
const poseidon = privacy_zig.poseidon;
const merkle = privacy_zig.merkle;

// ============================================================================
// Types matching on-chain program
// ============================================================================

/// A commitment to a deposit
const Commitment = [32]u8;

/// A nullifier (prevents double-spend)
const Nullifier = [32]u8;

/// Deposit note (Alice keeps this secret)
const DepositNote = struct {
    /// Random nullifier seed
    nullifier: [32]u8,
    /// Random secret
    secret: [32]u8,
    /// The amount deposited
    amount: u64,
    /// The commitment (public)
    commitment: Commitment,
    /// Leaf index in merkle tree
    leaf_index: ?u64,

    /// Create a new deposit note
    pub fn create(amount: u64) DepositNote {
        var nullifier: [32]u8 = undefined;
        var secret: [32]u8 = undefined;
        std.crypto.random.bytes(&nullifier);
        std.crypto.random.bytes(&secret);

        // commitment = hash(nullifier, secret, amount)
        var amount_bytes: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u64, amount_bytes[24..32], amount, .big);

        const commitment = poseidon.hashMany(&[_][32]u8{
            nullifier,
            secret,
            amount_bytes,
        });

        return .{
            .nullifier = nullifier,
            .secret = secret,
            .amount = amount,
            .commitment = commitment,
            .leaf_index = null,
        };
    }

    /// Compute the nullifier hash (used to prevent double-spend)
    pub fn computeNullifierHash(self: *const DepositNote) Nullifier {
        return poseidon.hash2(self.nullifier, self.secret);
    }
};

// ============================================================================
// Simulated On-Chain State
// ============================================================================

const PoolState = struct {
    /// Merkle tree of commitments
    tree: merkle.MerkleTree(20),
    /// Used nullifiers
    nullifiers: std.AutoHashMap(Nullifier, void),
    /// Pool balance
    balance: u64,
    /// Allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !PoolState {
        return .{
            .tree = try merkle.MerkleTree(20).init(allocator),
            .nullifiers = std.AutoHashMap(Nullifier, void).init(allocator),
            .balance = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PoolState) void {
        self.tree.deinit();
        self.nullifiers.deinit();
    }
};

// ============================================================================
// Pool Operations (simulating on-chain)
// ============================================================================

/// Deposit tokens into the pool
fn deposit(pool: *PoolState, note: *DepositNote, amount: u64) !void {
    // 1. Add commitment to merkle tree
    const leaf_index = try pool.tree.insert(note.commitment);

    // 2. Update note with leaf index
    note.leaf_index = @intCast(leaf_index);

    // 3. Update pool balance
    pool.balance += amount;

    std.debug.print("  ✓ Deposited {d} lamports, leaf index: {d}\n", .{ amount, leaf_index });
}

/// Withdraw tokens from the pool (simplified - no ZK proof)
fn withdraw(
    pool: *PoolState,
    nullifier_hash: Nullifier,
    note: DepositNote,
    recipient: [32]u8,
    amount: u64,
) !void {
    // 1. Check nullifier not used
    if (pool.nullifiers.contains(nullifier_hash)) {
        return error.NullifierAlreadyUsed;
    }

    // 2. Get merkle proof and verify
    const proof = try pool.tree.getProof(pool.allocator, note.leaf_index.?);
    defer pool.allocator.free(proof.path);
    defer pool.allocator.free(proof.indices);

    if (!proof.verify(pool.tree.root, note.commitment)) {
        return error.InvalidMerkleProof;
    }

    // 3. Verify nullifier hash matches
    const expected_nullifier = note.computeNullifierHash();
    if (!std.mem.eql(u8, &expected_nullifier, &nullifier_hash)) {
        return error.InvalidNullifier;
    }

    // 4. In real implementation: verify ZK proof here
    // The proof demonstrates knowledge of (nullifier, secret) without revealing them

    // 5. Mark nullifier as used
    try pool.nullifiers.put(nullifier_hash, {});

    // 6. Transfer funds
    pool.balance -= amount;

    std.debug.print("  ✓ Withdrew {d} lamports to {x}...\n", .{ amount, recipient[0..4].* });
}

// ============================================================================
// Example Scenario
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           ANONYMOUS TRANSFER USING PRIVACY POOL              ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║                                                              ║\n", .{});
    std.debug.print("║  Scenario: Alice wants to send 1 SOL to Bob anonymously      ║\n", .{});
    std.debug.print("║                                                              ║\n", .{});
    std.debug.print("║  Normal: Alice → Bob (visible on chain)                      ║\n", .{});
    std.debug.print("║  Private: Alice → Pool → Bob (no visible link)               ║\n", .{});
    std.debug.print("║                                                              ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Initialize pool
    var pool = try PoolState.init(allocator);
    defer pool.deinit();

    // ========================================
    // Step 1: Alice creates deposit note
    // ========================================
    std.debug.print("── Step 1: Alice creates deposit note ──\n", .{});

    const amount: u64 = 1_000_000_000; // 1 SOL
    var alice_note = DepositNote.create(amount);

    std.debug.print("  Amount: {d} lamports (1 SOL)\n", .{amount});
    std.debug.print("  Note created (Alice keeps this SECRET)\n", .{});
    std.debug.print("\n", .{});

    // ========================================
    // Step 2: Alice deposits to pool
    // ========================================
    std.debug.print("── Step 2: Alice deposits to Privacy Pool ──\n", .{});

    try deposit(&pool, &alice_note, amount);
    std.debug.print("  Pool balance: {d} lamports\n", .{pool.balance});
    std.debug.print("\n", .{});

    // Simulate other users depositing (increases anonymity set)
    std.debug.print("── Other users also deposit (anonymity set grows) ──\n", .{});
    for (0..5) |_| {
        var other_note = DepositNote.create(1_000_000_000);
        try deposit(&pool, &other_note, 1_000_000_000);
    }
    std.debug.print("  Anonymity set size: 6 depositors\n", .{});
    std.debug.print("  Pool balance: {d} lamports\n", .{pool.balance});
    std.debug.print("\n", .{});

    // ========================================
    // Step 3: Alice prepares withdrawal
    // ========================================
    std.debug.print("── Step 3: Alice prepares withdrawal ──\n", .{});

    // Bob's address (brand new, never used)
    var bob_address: [32]u8 = undefined;
    std.crypto.random.bytes(&bob_address);

    const nullifier_hash = alice_note.computeNullifierHash();

    std.debug.print("  Generated nullifier hash: {x}...\n", .{nullifier_hash[0..8].*});
    std.debug.print("  In production: Generate ZK-SNARK proof here\n", .{});
    std.debug.print("\n", .{});

    // ========================================
    // Step 4: Submit withdrawal (can use relayer)
    // ========================================
    std.debug.print("── Step 4: Submit withdrawal to Bob ──\n", .{});
    std.debug.print("  Bob's address: {x}...\n", .{bob_address[0..8].*});

    try withdraw(&pool, nullifier_hash, alice_note, bob_address, amount);
    std.debug.print("  Pool balance: {d} lamports\n", .{pool.balance});
    std.debug.print("\n", .{});

    // ========================================
    // Privacy Analysis
    // ========================================
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                     PRIVACY ANALYSIS                         ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║                                                              ║\n", .{});
    std.debug.print("║  What blockchain observers see:                              ║\n", .{});
    std.debug.print("║  ─────────────────────────────                               ║\n", .{});
    std.debug.print("║  • 6 deposits of 1 SOL each                                  ║\n", .{});
    std.debug.print("║  • 1 withdrawal of 1 SOL to Bob's address                    ║\n", .{});
    std.debug.print("║  • Nullifier hash (prevents double-spend)                    ║\n", .{});
    std.debug.print("║                                                              ║\n", .{});
    std.debug.print("║  What observers CANNOT see:                                  ║\n", .{});
    std.debug.print("║  ─────────────────────────────                               ║\n", .{});
    std.debug.print("║  • WHICH deposit is being withdrawn (1 of 6)                 ║\n", .{});
    std.debug.print("║  • WHO deposited the funds (Alice's identity)                ║\n", .{});
    std.debug.print("║  • Any link between Alice and Bob                            ║\n", .{});
    std.debug.print("║                                                              ║\n", .{});
    std.debug.print("║  Anonymity: 1/6 = 16.7% probability of linking               ║\n", .{});
    std.debug.print("║  With more deposits, anonymity increases                     ║\n", .{});
    std.debug.print("║                                                              ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});

    // ========================================
    // Prevent double-spend
    // ========================================
    std.debug.print("\n── Double-spend prevention ──\n", .{});
    std.debug.print("  Alice tries to withdraw again...\n", .{});

    const result = withdraw(&pool, nullifier_hash, alice_note, bob_address, amount);
    if (result) |_| {
        std.debug.print("  ERROR: Double-spend succeeded!\n", .{});
    } else |err| {
        std.debug.print("  ✓ Blocked: {}\n", .{err});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "deposit note creation" {
    const note = DepositNote.create(1_000_000_000);
    try std.testing.expect(note.amount == 1_000_000_000);
    try std.testing.expect(note.leaf_index == null);
}

test "deposit and withdraw" {
    var pool = try PoolState.init(std.testing.allocator);
    defer pool.deinit();

    // Deposit
    var note = DepositNote.create(1000);
    try deposit(&pool, &note, 1000);
    try std.testing.expectEqual(@as(u64, 1000), pool.balance);

    // Withdraw
    const nullifier_hash = note.computeNullifierHash();
    try withdraw(&pool, nullifier_hash, note, [_]u8{1} ** 32, 1000);
    try std.testing.expectEqual(@as(u64, 0), pool.balance);
}

test "double spend prevented" {
    var pool = try PoolState.init(std.testing.allocator);
    defer pool.deinit();

    var note = DepositNote.create(1000);
    try deposit(&pool, &note, 1000);

    const nullifier_hash = note.computeNullifierHash();

    // First withdraw succeeds
    try withdraw(&pool, nullifier_hash, note, [_]u8{1} ** 32, 1000);

    // Second withdraw fails
    try std.testing.expectError(
        error.NullifierAlreadyUsed,
        withdraw(&pool, nullifier_hash, note, [_]u8{1} ** 32, 1000),
    );
}
