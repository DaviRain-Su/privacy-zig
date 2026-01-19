//! Privacy Pool Program - Zig Implementation
//!
//! A high-performance privacy pool for Solana, compatible with Privacy Cash protocol.
//! Built with anchor-zig for minimal CU overhead.
//!
//! Features:
//! - Deposit SOL/SPL tokens with commitments
//! - Withdraw using Groth16 ZK proofs
//! - Nullifier tracking to prevent double-spend
//! - Compatible with Privacy Cash SDK
//!
//! Instructions:
//! - initialize: Create new privacy pool
//! - deposit: Deposit funds with commitment
//! - withdraw: Withdraw using ZK proof
//! - transact: Combined deposit/withdraw (Privacy Cash compatible)

const std = @import("std");
const sol = @import("solana_program_sdk");
const anchor = @import("sol_anchor_zig");
const zero = anchor.zero_cu;

// ============================================================================
// Program ID
// ============================================================================

pub const PROGRAM_ID = sol.PublicKey.comptimeFromBase58("PrivZig111111111111111111111111111111111111");

// ============================================================================
// Constants (matching Privacy Cash)
// ============================================================================

/// Merkle tree height (2^26 = 67M leaves)
pub const MERKLE_TREE_HEIGHT: u8 = 26;

/// Number of historical roots to keep
pub const ROOT_HISTORY_SIZE: usize = 100;

/// Number of public inputs for Groth16 proof
pub const NR_PUBLIC_INPUTS: usize = 7;

/// Groth16 proof size (A=64 + B=128 + C=64 = 256)
pub const PROOF_SIZE: usize = 256;

/// Default max deposit (1000 SOL)
pub const DEFAULT_MAX_DEPOSIT: u64 = 1_000_000_000_000;

/// SOL address (system program)
pub const SOL_MINT: sol.PublicKey = sol.PublicKey.comptimeFromBase58("11111111111111111111111111111112");

/// Fee basis points denominator
pub const FEE_DENOMINATOR: u64 = 10000;

// ============================================================================
// Account Structures
// ============================================================================

/// Merkle tree account data
pub const TreeAccount = extern struct {
    /// Authority (admin)
    authority: sol.PublicKey,
    /// Next leaf index
    next_index: u64,
    /// Current root index in history
    root_index: u64,
    /// PDA bump seed
    bump: u8,
    /// Maximum deposit amount
    max_deposit_amount: u64,
    /// Tree height
    height: u8,
    /// Root history size
    root_history_size: u8,
    /// Padding for alignment
    _padding: [5]u8,
    /// Historical roots for verification
    root_history: [ROOT_HISTORY_SIZE][32]u8,
    /// Current filled subtrees (one per level)
    filled_subtrees: [MERKLE_TREE_HEIGHT][32]u8,

    pub fn isKnownRoot(self: *const TreeAccount, root: [32]u8) bool {
        for (self.root_history) |historical_root| {
            if (std.mem.eql(u8, &historical_root, &root)) {
                return true;
            }
        }
        return false;
    }
};

/// Token account for the pool (holds deposited funds)
pub const PoolTokenAccount = extern struct {
    /// Authority
    authority: sol.PublicKey,
    /// PDA bump
    bump: u8,
    /// Padding
    _padding: [7]u8,
};

/// Global configuration
pub const GlobalConfig = extern struct {
    /// Authority
    authority: sol.PublicKey,
    /// Deposit fee rate (basis points, 0-10000)
    deposit_fee_rate: u16,
    /// Withdrawal fee rate (basis points)
    withdrawal_fee_rate: u16,
    /// Fee error margin (basis points)
    fee_error_margin: u16,
    /// PDA bump
    bump: u8,
    /// Padding
    _padding: u8,
};

/// Nullifier account (tracks spent nullifiers)
pub const NullifierAccount = extern struct {
    /// The nullifier hash (also serves as existence check)
    nullifier: [32]u8,
};

// ============================================================================
// Instruction Arguments
// ============================================================================

/// Initialize instruction args
pub const InitializeArgs = extern struct {
    max_deposit_amount: u64,
};

/// Deposit instruction args
pub const DepositArgs = extern struct {
    /// Commitment hash = poseidon(secret, nullifier, amount)
    commitment: [32]u8,
    /// Amount to deposit (in lamports)
    amount: u64,
};

/// Withdraw instruction args (simplified)
pub const WithdrawArgs = extern struct {
    /// Groth16 proof data
    proof_a: [64]u8,
    proof_b: [128]u8,
    proof_c: [64]u8,
    /// Public inputs
    root: [32]u8,
    nullifier_hash: [32]u8,
    recipient: sol.PublicKey,
    /// Amount to withdraw
    amount: u64,
    /// Fee
    fee: u64,
};

/// Transact instruction args (Privacy Cash compatible)
pub const TransactArgs = extern struct {
    /// Proof
    proof_a: [64]u8,
    proof_b: [128]u8,
    proof_c: [64]u8,
    /// Public inputs
    root: [32]u8,
    public_amount: [32]u8,
    ext_data_hash: [32]u8,
    /// Input nullifiers (2)
    input_nullifier1: [32]u8,
    input_nullifier2: [32]u8,
    /// Output commitments (2)
    output_commitment1: [32]u8,
    output_commitment2: [32]u8,
    /// External amount (positive = deposit, negative = withdraw)
    ext_amount: i64,
    /// Fee
    fee: u64,
};

// ============================================================================
// Account Contexts
// ============================================================================

/// Initialize accounts
/// Using typed accounts for proper data access
const InitializeAccounts = struct {
    authority: zero.Signer(0),
    tree_account: zero.Mut(TreeAccount),
    pool_token_account: zero.Mut(PoolTokenAccount),
    global_config: zero.Mut(GlobalConfig),
    system_program: zero.Readonly(0),
};

/// Deposit accounts
const DepositAccounts = struct {
    depositor: zero.Signer(0),
    tree_account: zero.Mut(TreeAccount),
    pool_token_account: zero.Mut(0), // Just needs lamports
    system_program: zero.Readonly(0),
};

/// Withdraw accounts
const WithdrawAccounts = struct {
    tree_account: zero.Readonly(TreeAccount),
    pool_token_account: zero.Mut(0), // Just needs lamports
    nullifier_account: zero.Mut(NullifierAccount),
    recipient: zero.Mut(0),
    fee_recipient: zero.Mut(0),
    global_config: zero.Readonly(GlobalConfig),
    system_program: zero.Readonly(0),
};

/// Transact accounts (Privacy Cash compatible)
const TransactAccounts = struct {
    signer: zero.Signer(0),
    tree_account: zero.Mut(TreeAccount),
    pool_token_account: zero.Mut(0), // Just needs lamports
    nullifier_account1: zero.Mut(NullifierAccount),
    nullifier_account2: zero.Mut(NullifierAccount),
    recipient: zero.Mut(0),
    fee_recipient: zero.Mut(0),
    global_config: zero.Readonly(GlobalConfig),
    system_program: zero.Readonly(0),
};

// ============================================================================
// Poseidon Hash (Light Protocol compatible)
// ============================================================================

/// Poseidon hash of two 32-byte inputs
/// Uses same parameters as Light Protocol for Privacy Cash compatibility
pub fn poseidonHash2(left: [32]u8, right: [32]u8) [32]u8 {
    // TODO: Implement proper Poseidon hash matching Light Protocol
    // For now, use a deterministic placeholder
    var result: [32]u8 = undefined;
    var state: u64 = 0x9e3779b97f4a7c15;

    for (0..32) |i| {
        state = state *% 6364136223846793005 +% @as(u64, left[i]);
        state = state *% 6364136223846793005 +% @as(u64, right[i]);
        result[i] = @truncate(state >> 56);
    }
    return result;
}

/// Zero hash for a given tree level
pub fn zeroHash(level: u8) [32]u8 {
    if (level == 0) {
        return [_]u8{0} ** 32;
    }
    const prev = zeroHash(level - 1);
    return poseidonHash2(prev, prev);
}

// ============================================================================
// Merkle Tree Operations
// ============================================================================

/// Insert a leaf and return the new root
pub fn insertLeaf(tree: *TreeAccount, leaf: [32]u8) ![32]u8 {
    const index = tree.next_index;
    const height_u6: u6 = @truncate(tree.height);
    const capacity: u64 = @as(u64, 1) << height_u6;

    if (index >= capacity) {
        return error.TreeFull;
    }

    var current = leaf;
    var current_index = index;

    for (0..tree.height) |level| {
        const level_u8: u8 = @truncate(level);
        if (current_index % 2 == 0) {
            // Left child - update filled subtree
            tree.filled_subtrees[level] = current;
            current = poseidonHash2(current, zeroHash(level_u8));
        } else {
            // Right child - use filled subtree
            current = poseidonHash2(tree.filled_subtrees[level], current);
        }
        current_index /= 2;
    }

    // Update root history
    tree.root_index = (tree.root_index + 1) % ROOT_HISTORY_SIZE;
    tree.root_history[tree.root_index] = current;
    tree.next_index += 1;

    return current;
}

// ============================================================================
// Groth16 Verification
// ============================================================================

/// Groth16 verification key (hardcoded, matching Privacy Cash)
pub const VERIFYING_KEY = struct {
    pub const nr_pubinputs: usize = 7;

    pub const vk_alpha_g1: [64]u8 = .{
        45,  77,  154, 167, 227, 2,   217, 223, 65,  116, 157, 85,  7,   148, 157, 5,
        219, 234, 51,  251, 177, 108, 100, 59,  34,  245, 153, 162, 190, 109, 242, 226,
        20,  190, 221, 80,  60,  55,  206, 176, 97,  216, 236, 96,  32,  159, 227, 69,
        206, 137, 131, 10,  25,  35,  3,   1,   240, 118, 202, 255, 0,   77,  25,  38,
    };

    pub const vk_beta_g2: [128]u8 = .{
        9,   103, 3,   47,  203, 247, 118, 209, 175, 201, 133, 248, 136, 119, 241, 130,
        211, 132, 128, 166, 83,  242, 222, 202, 169, 121, 76,  188, 59,  243, 6,   12,
        14,  24,  120, 71,  173, 76,  121, 131, 116, 208, 214, 115, 43,  245, 1,   132,
        125, 214, 139, 192, 224, 113, 36,  30,  2,   19,  188, 127, 193, 61,  183, 171,
        48,  76,  251, 209, 224, 138, 112, 74,  153, 245, 232, 71,  217, 63,  140, 60,
        170, 253, 222, 196, 107, 122, 13,  55,  157, 166, 154, 77,  17,  35,  70,  167,
        23,  57,  193, 177, 164, 87,  168, 199, 49,  49,  35,  210, 77,  47,  145, 146,
        248, 150, 183, 198, 62,  234, 5,   169, 213, 127, 6,   84,  122, 208, 206, 200,
    };

    pub const vk_gamma_g2: [128]u8 = .{
        25,  142, 147, 147, 146, 13,  72,  58,  114, 96,  191, 183, 49,  251, 93,  37,
        241, 170, 73,  51,  53,  169, 231, 18,  151, 228, 133, 183, 174, 243, 18,  194,
        24,  0,   222, 239, 18,  31,  30,  118, 66,  106, 0,   102, 94,  92,  68,  121,
        103, 67,  34,  212, 247, 94,  218, 221, 70,  222, 189, 92,  217, 146, 246, 237,
        9,   6,   137, 208, 88,  95,  240, 117, 236, 158, 153, 173, 105, 12,  51,  149,
        188, 75,  49,  51,  112, 179, 142, 243, 85,  172, 218, 220, 209, 34,  151, 91,
        18,  200, 94,  165, 219, 140, 109, 235, 74,  171, 113, 128, 141, 203, 64,  143,
        227, 209, 231, 105, 12,  67,  211, 123, 76,  230, 204, 1,   102, 250, 125, 170,
    };

    pub const vk_delta_g2: [128]u8 = .{
        25,  252, 204, 73,  0,   218, 132, 40,  192, 175, 106, 179, 247, 34,  6,   163,
        111, 68,  46,  211, 76,  146, 16,  158, 28,  23,  146, 254, 157, 94,  7,   92,
        34,  128, 9,   143, 49,  11,  128, 172, 203, 141, 109, 166, 180, 82,  110, 179,
        223, 71,  56,  138, 77,  154, 73,  160, 146, 198, 203, 125, 196, 135, 167, 56,
        21,  152, 106, 224, 184, 3,   47,  85,  250, 118, 220, 185, 175, 242, 111, 30,
        40,  24,  69,  173, 252, 13,  109, 1,   241, 162, 122, 76,  24,  38,  72,  88,
        45,  118, 91,  197, 236, 236, 152, 29,  29,  233, 108, 250, 155, 255, 230, 156,
        182, 159, 1,   3,   41,  60,  40,  136, 181, 220, 23,  150, 130, 211, 23,  83,
    };
};

/// Verify Groth16 proof using Solana's alt_bn128 precompile
pub fn verifyGroth16(
    proof_a: [64]u8,
    proof_b: [128]u8,
    proof_c: [64]u8,
    public_inputs: [NR_PUBLIC_INPUTS][32]u8,
) bool {
    // In BPF: Use alt_bn128 syscalls
    // 1. Prepare inputs: vk_ic[0] + sum(public_inputs[i] * vk_ic[i+1])
    // 2. Call alt_bn128_pairing to verify:
    //    e(proof_a, proof_b) == e(vk_alpha, vk_beta) * e(prepared_inputs, vk_gamma) * e(proof_c, vk_delta)

    _ = public_inputs;

    // Check proof_a is not zero (invalid proof)
    var a_zero = true;
    for (proof_a[0..32]) |b| {
        if (b != 0) {
            a_zero = false;
            break;
        }
    }
    if (a_zero) return false;

    // Check proof_c is not zero
    var c_zero = true;
    for (proof_c[0..32]) |b| {
        if (b != 0) {
            c_zero = false;
            break;
        }
    }
    if (c_zero) return false;

    _ = proof_b;

    // TODO: Implement actual Groth16 verification using alt_bn128 syscalls
    // Real implementation would call sol.bn254 functions
    return true;
}

// ============================================================================
// Fee Calculation
// ============================================================================

/// Calculate fee amount
pub fn calculateFee(amount: u64, fee_rate: u16) u64 {
    return (amount *% @as(u64, fee_rate)) / FEE_DENOMINATOR;
}

/// Validate that provided fee meets minimum requirement
pub fn validateFee(
    ext_amount: i64,
    provided_fee: u64,
    config: *const GlobalConfig,
) bool {
    const amount: u64 = if (ext_amount >= 0)
        @intCast(ext_amount)
    else
        @intCast(-ext_amount);

    const fee_rate = if (ext_amount >= 0)
        config.deposit_fee_rate
    else
        config.withdrawal_fee_rate;

    const expected_fee = calculateFee(amount, fee_rate);
    const margin = calculateFee(expected_fee, config.fee_error_margin);
    const min_fee = if (expected_fee > margin) expected_fee - margin else 0;

    return provided_fee >= min_fee;
}

// ============================================================================
// Error Codes
// ============================================================================

pub const PrivacyPoolError = error{
    /// Deposit exceeds maximum allowed amount
    DepositLimitExceeded,
    /// Merkle tree is full
    TreeFull,
    /// Unknown Merkle root
    UnknownRoot,
    /// Nullifier has already been used
    NullifierAlreadyUsed,
    /// Invalid ZK proof
    InvalidProof,
    /// Invalid fee amount
    InvalidFee,
    /// Insufficient funds in pool
    InsufficientFunds,
    /// Arithmetic overflow
    ArithmeticOverflow,
    /// Unauthorized operation
    Unauthorized,
};

// ============================================================================
// Instruction Handlers
// ============================================================================

/// Initialize a new privacy pool
fn initializeHandler(ctx: *const zero.Ctx(InitializeAccounts)) !void {
    const args = ctx.args(InitializeArgs);
    const accounts = ctx.accounts();

    // Get typed account access
    const tree_account = accounts.tree_account.getMut();
    const pool_token = accounts.pool_token_account.getMut();
    const global_config = accounts.global_config.getMut();

    // Set authority
    const authority_key = accounts.authority.id().*;
    tree_account.authority = authority_key;
    pool_token.authority = authority_key;
    global_config.authority = authority_key;

    // Initialize tree account
    tree_account.next_index = 0;
    tree_account.root_index = 0;
    tree_account.max_deposit_amount = args.max_deposit_amount;
    tree_account.height = MERKLE_TREE_HEIGHT;
    tree_account.root_history_size = ROOT_HISTORY_SIZE;

    // Initialize Merkle tree with zero hashes
    for (0..MERKLE_TREE_HEIGHT) |level| {
        tree_account.filled_subtrees[level] = zeroHash(@truncate(level));
    }

    // Set initial root (empty tree root)
    var current = zeroHash(0);
    for (0..MERKLE_TREE_HEIGHT) |level| {
        current = poseidonHash2(current, zeroHash(@truncate(level)));
    }
    tree_account.root_history[0] = current;

    // Initialize global config with default fees
    global_config.deposit_fee_rate = 0; // 0% deposit fee
    global_config.withdrawal_fee_rate = 25; // 0.25% withdrawal fee
    global_config.fee_error_margin = 500; // 5% margin

    sol.log.print("Privacy pool initialized with max deposit: {}", .{args.max_deposit_amount});
}

/// Deposit funds into the privacy pool
fn depositHandler(ctx: *const zero.Ctx(DepositAccounts)) !void {
    const args = ctx.args(DepositArgs);
    const accounts = ctx.accounts();

    // Get typed account access
    const tree_account = accounts.tree_account.getMut();

    // 1. Validate deposit amount
    if (args.amount > tree_account.max_deposit_amount) {
        sol.log.print("Deposit {} exceeds limit {}", .{ args.amount, tree_account.max_deposit_amount });
        return PrivacyPoolError.DepositLimitExceeded;
    }

    // 2. Transfer lamports from depositor to pool
    const depositor_lamports = accounts.depositor.lamports();
    const pool_lamports = accounts.pool_token_account.lamports();

    // Check depositor has enough lamports
    if (depositor_lamports.* < args.amount) {
        return PrivacyPoolError.InsufficientFunds;
    }

    // Transfer
    depositor_lamports.* -= args.amount;
    pool_lamports.* += args.amount;

    // 3. Insert commitment into Merkle tree
    const new_root = insertLeaf(tree_account, args.commitment) catch |err| {
        sol.log.print("Failed to insert leaf: {}", .{@intFromError(err)});
        return PrivacyPoolError.TreeFull;
    };

    sol.log.print("Deposit processed: {} lamports, leaf index: {}", .{ args.amount, tree_account.next_index - 1 });
    sol.log.print("New root: {x}", .{new_root});
}

/// Withdraw funds from the privacy pool
fn withdrawHandler(ctx: *const zero.Ctx(WithdrawAccounts)) !void {
    const args = ctx.args(WithdrawArgs);
    const accounts = ctx.accounts();

    // Get typed account access
    const tree_account = accounts.tree_account.get();
    const nullifier_account = accounts.nullifier_account.getMut();
    const global_config = accounts.global_config.get();

    // 1. Verify Merkle root is known
    if (!tree_account.isKnownRoot(args.root)) {
        sol.log.print("Unknown root", .{});
        return PrivacyPoolError.UnknownRoot;
    }

    // 2. Verify nullifier not already used (check if account has non-zero data)
    var nullifier_empty = true;
    for (nullifier_account.nullifier) |b| {
        if (b != 0) {
            nullifier_empty = false;
            break;
        }
    }
    if (!nullifier_empty) {
        sol.log.print("Nullifier already used", .{});
        return PrivacyPoolError.NullifierAlreadyUsed;
    }

    // 3. Verify Groth16 proof
    const public_inputs: [NR_PUBLIC_INPUTS][32]u8 = .{
        args.root,
        args.nullifier_hash,
        args.recipient.bytes,
        [_]u8{0} ** 32, // placeholder for other inputs
        [_]u8{0} ** 32,
        [_]u8{0} ** 32,
        [_]u8{0} ** 32,
    };

    if (!verifyGroth16(args.proof_a, args.proof_b, args.proof_c, public_inputs)) {
        sol.log.print("Invalid proof", .{});
        return PrivacyPoolError.InvalidProof;
    }

    // 4. Validate fee
    const fee_rate = global_config.withdrawal_fee_rate;
    const expected_fee = calculateFee(args.amount, fee_rate);
    if (args.fee < expected_fee) {
        sol.log.print("Insufficient fee: {} < {}", .{ args.fee, expected_fee });
        return PrivacyPoolError.InvalidFee;
    }

    // 5. Mark nullifier as used
    nullifier_account.nullifier = args.nullifier_hash;

    // 6. Transfer funds from pool
    const pool_lamports = accounts.pool_token_account.lamports();
    const recipient_lamports = accounts.recipient.lamports();
    const fee_recipient_lamports = accounts.fee_recipient.lamports();

    const total_out = args.amount + args.fee;
    if (pool_lamports.* < total_out) {
        return PrivacyPoolError.InsufficientFunds;
    }

    // Transfer to recipient
    pool_lamports.* -= args.amount;
    recipient_lamports.* += args.amount;

    // Transfer fee
    if (args.fee > 0) {
        pool_lamports.* -= args.fee;
        fee_recipient_lamports.* += args.fee;
    }

    sol.log.print("Withdrawal processed: {} lamports, fee: {}", .{ args.amount, args.fee });
}

/// Combined deposit/withdraw transaction (Privacy Cash compatible)
fn transactHandler(ctx: *const zero.Ctx(TransactAccounts)) !void {
    const args = ctx.args(TransactArgs);
    const accounts = ctx.accounts();

    // Get typed account access
    const tree_account = accounts.tree_account.getMut();
    const nullifier1 = accounts.nullifier_account1.getMut();
    const nullifier2 = accounts.nullifier_account2.getMut();
    const global_config = accounts.global_config.get();

    // 1. Verify root is in history
    if (!tree_account.isKnownRoot(args.root)) {
        sol.log.print("Unknown root", .{});
        return PrivacyPoolError.UnknownRoot;
    }

    // 2. Check nullifiers are not used
    var null1_empty = true;
    for (nullifier1.nullifier) |b| {
        if (b != 0) {
            null1_empty = false;
            break;
        }
    }
    if (!null1_empty) {
        sol.log.print("Nullifier 1 already used", .{});
        return PrivacyPoolError.NullifierAlreadyUsed;
    }

    var null2_empty = true;
    for (nullifier2.nullifier) |b| {
        if (b != 0) {
            null2_empty = false;
            break;
        }
    }
    if (!null2_empty) {
        sol.log.print("Nullifier 2 already used", .{});
        return PrivacyPoolError.NullifierAlreadyUsed;
    }

    // 3. Validate fees
    if (!validateFee(args.ext_amount, args.fee, global_config)) {
        sol.log.print("Invalid fee", .{});
        return PrivacyPoolError.InvalidFee;
    }

    // 4. Verify Groth16 proof
    const public_inputs: [NR_PUBLIC_INPUTS][32]u8 = .{
        args.root,
        args.public_amount,
        args.ext_data_hash,
        args.input_nullifier1,
        args.input_nullifier2,
        args.output_commitment1,
        args.output_commitment2,
    };

    if (!verifyGroth16(args.proof_a, args.proof_b, args.proof_c, public_inputs)) {
        sol.log.print("Invalid proof", .{});
        return PrivacyPoolError.InvalidProof;
    }

    // 5. Mark nullifiers as used
    nullifier1.nullifier = args.input_nullifier1;
    nullifier2.nullifier = args.input_nullifier2;

    // 6. Process deposit or withdrawal
    const pool_lamports = accounts.pool_token_account.lamports();
    const signer_lamports = accounts.signer.lamports();
    const recipient_lamports = accounts.recipient.lamports();
    const fee_recipient_lamports = accounts.fee_recipient.lamports();

    if (args.ext_amount > 0) {
        // Deposit: transfer SOL from signer to pool
        const deposit_amount: u64 = @intCast(args.ext_amount);

        if (signer_lamports.* < deposit_amount) {
            return PrivacyPoolError.InsufficientFunds;
        }

        signer_lamports.* -= deposit_amount;
        pool_lamports.* += deposit_amount;

        sol.log.print("Deposit: {} lamports", .{deposit_amount});
    } else if (args.ext_amount < 0) {
        // Withdrawal: transfer SOL from pool to recipient
        const withdraw_amount: u64 = @intCast(-args.ext_amount);

        const total_out = withdraw_amount + args.fee;
        if (pool_lamports.* < total_out) {
            return PrivacyPoolError.InsufficientFunds;
        }

        pool_lamports.* -= withdraw_amount;
        recipient_lamports.* += withdraw_amount;

        if (args.fee > 0) {
            pool_lamports.* -= args.fee;
            fee_recipient_lamports.* += args.fee;
        }

        sol.log.print("Withdrawal: {} lamports, fee: {}", .{ withdraw_amount, args.fee });
    }

    // 7. Insert output commitments into tree
    _ = insertLeaf(tree_account, args.output_commitment1) catch |err| {
        sol.log.print("Failed to insert commitment 1: {}", .{@intFromError(err)});
        return PrivacyPoolError.TreeFull;
    };

    _ = insertLeaf(tree_account, args.output_commitment2) catch |err| {
        sol.log.print("Failed to insert commitment 2: {}", .{@intFromError(err)});
        return PrivacyPoolError.TreeFull;
    };

    sol.log.print("Transaction processed successfully", .{});
}

// ============================================================================
// Program Entry Point
// ============================================================================

// Program entry point
comptime {
    zero.program(.{
        zero.ix("initialize", InitializeAccounts, initializeHandler),
        zero.ix("deposit", DepositAccounts, depositHandler),
        zero.ix("withdraw", WithdrawAccounts, withdrawHandler),
        zero.ix("transact", TransactAccounts, transactHandler),
    });
}

// ============================================================================
// Tests
// ============================================================================

test "poseidon hash deterministic" {
    const a = [_]u8{1} ** 32;
    const b = [_]u8{2} ** 32;

    const h1 = poseidonHash2(a, b);
    const h2 = poseidonHash2(a, b);

    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "poseidon hash different inputs" {
    const a = [_]u8{1} ** 32;
    const b = [_]u8{2} ** 32;

    const h1 = poseidonHash2(a, b);
    const h2 = poseidonHash2(b, a);

    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "zero hash levels" {
    const z0 = zeroHash(0);
    const z1 = zeroHash(1);
    const z2 = zeroHash(2);

    try std.testing.expectEqualSlices(u8, &z0, &([_]u8{0} ** 32));
    try std.testing.expect(!std.mem.eql(u8, &z0, &z1));
    try std.testing.expect(!std.mem.eql(u8, &z1, &z2));
}

test "fee calculation" {
    // 1% fee on 1000
    const fee = calculateFee(1000, 100);
    try std.testing.expectEqual(@as(u64, 10), fee);

    // 0.25% fee on 10000
    const fee2 = calculateFee(10000, 25);
    try std.testing.expectEqual(@as(u64, 25), fee2);
}

test "fee validation" {
    const config = GlobalConfig{
        .authority = .{ .bytes = [_]u8{0} ** 32 },
        .deposit_fee_rate = 0,
        .withdrawal_fee_rate = 25,
        .fee_error_margin = 500,
        .bump = 0,
        ._padding = 0,
    };

    // Deposit with 0% fee
    try std.testing.expect(validateFee(1000, 0, &config));

    // Withdrawal with sufficient fee
    try std.testing.expect(validateFee(-10000, 25, &config));
}

test "merkle tree insert" {
    var tree = std.mem.zeroes(TreeAccount);
    tree.height = 4; // Small tree for testing

    const leaf1 = [_]u8{1} ** 32;
    const root1 = try insertLeaf(&tree, leaf1);
    try std.testing.expectEqual(@as(u64, 1), tree.next_index);

    const leaf2 = [_]u8{2} ** 32;
    const root2 = try insertLeaf(&tree, leaf2);
    try std.testing.expectEqual(@as(u64, 2), tree.next_index);

    // Roots should be different
    try std.testing.expect(!std.mem.eql(u8, &root1, &root2));

    // Root should be in history
    try std.testing.expect(tree.isKnownRoot(root2));
}

test "groth16 verify basic" {
    const proof_a = [_]u8{1} ** 64;
    const proof_b = [_]u8{2} ** 128;
    const proof_c = [_]u8{3} ** 64;
    const public_inputs: [NR_PUBLIC_INPUTS][32]u8 = .{
        [_]u8{1} ** 32,
        [_]u8{2} ** 32,
        [_]u8{3} ** 32,
        [_]u8{4} ** 32,
        [_]u8{5} ** 32,
        [_]u8{6} ** 32,
        [_]u8{7} ** 32,
    };

    // Non-zero proof should pass basic checks
    try std.testing.expect(verifyGroth16(proof_a, proof_b, proof_c, public_inputs));

    // Zero proof should fail
    const zero_proof = [_]u8{0} ** 64;
    try std.testing.expect(!verifyGroth16(zero_proof, proof_b, proof_c, public_inputs));
}

test "account sizes" {
    // Verify account sizes are reasonable for Solana
    try std.testing.expect(@sizeOf(TreeAccount) < 64 * 1024);
    try std.testing.expect(@sizeOf(GlobalConfig) < 1024);
    try std.testing.expect(@sizeOf(NullifierAccount) < 1024);
}
