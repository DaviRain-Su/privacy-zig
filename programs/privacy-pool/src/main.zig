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

const builtin = @import("builtin");
const syscalls = sol.syscalls;

/// Check if running on Solana BPF/SBF (where syscalls are available)
const is_bpf_program = !builtin.is_test and
    ((builtin.os.tag == .freestanding and builtin.cpu.arch == .bpfel) or
    builtin.cpu.arch == .sbf);

/// Poseidon parameter set for BN254 with x^5 S-box (Light Protocol compatible)
const POSEIDON_PARAMS_BN254_X5: u64 = 0;

/// Big-endian mode for Poseidon syscall
const POSEIDON_ENDIANNESS_BE: u64 = 0;

/// Poseidon hash of two 32-byte inputs
/// Uses Solana syscall on-chain, software implementation off-chain/tests
pub fn poseidonHash2(left: [32]u8, right: [32]u8) [32]u8 {
    if (comptime is_bpf_program) {
        return poseidonHash2Syscall(left, right);
    } else {
        return poseidonHash2Software(left, right);
    }
}

/// Poseidon hash using Solana syscall (on-chain)
fn poseidonHash2Syscall(left: [32]u8, right: [32]u8) [32]u8 {
    var input: [64]u8 = undefined;
    @memcpy(input[0..32], &left);
    @memcpy(input[32..64], &right);

    var result: [32]u8 = undefined;

    // Use syscall from solana-program-sdk-zig
    const ret = syscalls.sol_poseidon(
        POSEIDON_PARAMS_BN254_X5,
        POSEIDON_ENDIANNESS_BE,
        &input,
        64,
        &result,
    );

    if (ret != 0) {
        return [_]u8{0} ** 32;
    }

    return result;
}

/// Poseidon hash using software implementation (tests/off-chain)
/// Simplified but deterministic implementation
fn poseidonHash2Software(left: [32]u8, right: [32]u8) [32]u8 {
    // Use a simple but asymmetric hash based on the sponge construction
    var state: [32]u8 = [_]u8{0} ** 32;
    
    // Absorb left with position marker
    for (0..32) |i| {
        state[i] ^= left[i];
        state[(i + 1) % 32] +%= left[i] *% 2;
    }
    
    // Mix
    state = mixState(state);
    
    // Absorb right with different position marker
    for (0..32) |i| {
        state[i] ^= right[i];
        state[(i + 2) % 32] +%= right[i] *% 3;
    }
    
    // Final mix
    state = mixState(state);
    state = mixState(state);
    
    return state;
}

/// Mix the state (simplified permutation)
fn mixState(input: [32]u8) [32]u8 {
    var state = input;
    
    // Multiple rounds of mixing
    for (0..8) |round| {
        // Non-linear layer (S-box approximation)
        for (0..32) |i| {
            const x = state[i];
            state[i] = x ^ (x << 1) ^ (x >> 2) ^ @as(u8, @truncate(round + i + 1));
        }
        
        // Linear diffusion layer
        var temp: [32]u8 = undefined;
        for (0..32) |i| {
            temp[i] = state[i] +%
                state[(i + 1) % 32] *% 2 +%
                state[(i + 7) % 32] *% 3 +%
                state[(i + 13) % 32] *% 5 +%
                state[(i + 19) % 32] *% 7;
        }
        state = temp;
    }
    
    return state;
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

    /// IC points: IC[0], IC[1], ..., IC[7] for 7 public inputs
    /// These are G1 points used in the linear combination with public inputs
    /// Source: Privacy Cash verifyingkey2.json (trusted setup)
    pub const vk_ic: [8][64]u8 = .{
        // IC[0] - constant term
        .{
            0x23, 0x79, 0x17, 0xa2, 0x20, 0x65, 0xf7, 0x73, 0xb1, 0xc7, 0x32, 0x9e, 0x03, 0x3c, 0xbc, 0x5f,
            0x5b, 0x1d, 0x79, 0xd2, 0x35, 0x9b, 0xf5, 0xe2, 0xcb, 0xf5, 0xba, 0xa7, 0x27, 0x20, 0xa0, 0xca,
            0x16, 0x16, 0xa8, 0xa0, 0x7d, 0x2d, 0x38, 0x2d, 0x84, 0xd6, 0x14, 0xc6, 0x4c, 0x51, 0x02, 0x96,
            0x00, 0x3d, 0x56, 0x82, 0x69, 0xaa, 0x8d, 0xf4, 0x0d, 0xb4, 0x51, 0x4f, 0x12, 0xa6, 0x81, 0x81,
        },
        // IC[1] - merkle_root
        .{
            0x0d, 0x94, 0x3f, 0xea, 0xb9, 0x2a, 0x03, 0x9f, 0x7f, 0x18, 0xf0, 0xc8, 0x48, 0x18, 0xb0, 0x07,
            0xb5, 0xd7, 0xd4, 0x34, 0x0d, 0xa0, 0xac, 0xb6, 0xb1, 0x16, 0xeb, 0x04, 0xad, 0xe5, 0x19, 0x6c,
            0x2e, 0x3d, 0xe9, 0xb8, 0xb5, 0x98, 0x84, 0x67, 0xfc, 0x64, 0xe5, 0x90, 0xd9, 0x24, 0x27, 0xfe,
            0x43, 0xed, 0x46, 0xd6, 0xc0, 0xe7, 0x8c, 0x56, 0x71, 0x28, 0x0b, 0x58, 0x0c, 0x96, 0x9d, 0xe2,
        },
        // IC[2] - nullifier1
        .{
            0x1a, 0x69, 0x96, 0xcc, 0xb2, 0xca, 0x1a, 0x3e, 0x27, 0xb2, 0xb3, 0xe1, 0x85, 0x8c, 0x8a, 0x28,
            0x3c, 0xbb, 0x63, 0x39, 0xed, 0x07, 0xcb, 0x9f, 0xfb, 0x67, 0x2e, 0xcf, 0xdb, 0xba, 0x13, 0x40,
            0x00, 0x2a, 0x49, 0x05, 0x4c, 0x30, 0x73, 0x50, 0x60, 0x1d, 0xc5, 0xd5, 0xe4, 0xf0, 0x07, 0x90,
            0x8c, 0x03, 0x7f, 0x59, 0x57, 0xf7, 0x62, 0x99, 0xae, 0x51, 0x07, 0x9e, 0xb7, 0x50, 0x8b, 0x93,
        },
        // IC[3] - nullifier2
        .{
            0x06, 0xf9, 0x58, 0x68, 0x38, 0x4a, 0x90, 0x88, 0x81, 0xb0, 0x46, 0xd8, 0x12, 0x93, 0x4e, 0x8d,
            0x18, 0x5d, 0x5f, 0xf2, 0x44, 0x31, 0xd7, 0x98, 0xf6, 0x6e, 0x97, 0xf1, 0xe4, 0x3b, 0xe6, 0xbb,
            0x1d, 0x38, 0xba, 0xd2, 0xc8, 0xbe, 0x5d, 0x40, 0x6e, 0x00, 0x37, 0x69, 0xa6, 0x68, 0xd0, 0x2e,
            0x52, 0x51, 0x92, 0x88, 0xb3, 0x63, 0x68, 0xe8, 0x63, 0xf8, 0xa2, 0x89, 0x15, 0xd9, 0xdc, 0x4d,
        },
        // IC[4] - commitment1
        .{
            0x22, 0xa3, 0xaa, 0x5b, 0xfe, 0xd7, 0xdc, 0xaf, 0x47, 0x43, 0x38, 0x2b, 0xb2, 0x30, 0x5c, 0x07,
            0xaa, 0x7c, 0xc9, 0xe8, 0xcf, 0xca, 0x86, 0x50, 0x7b, 0x1f, 0x1a, 0xec, 0x4c, 0xaf, 0xba, 0x9b,
            0x2e, 0xfd, 0xec, 0xaa, 0x0c, 0xf8, 0x1e, 0x7f, 0x33, 0x88, 0x64, 0x33, 0x22, 0x07, 0xda, 0x15,
            0x85, 0x33, 0x94, 0xeb, 0x5c, 0xd2, 0x75, 0x86, 0x79, 0x4e, 0xa6, 0x5a, 0x0a, 0xc2, 0xc1, 0x94,
        },
        // IC[5] - commitment2
        .{
            0x24, 0xb4, 0x52, 0xce, 0xe7, 0xc3, 0x56, 0x29, 0x6a, 0x91, 0x15, 0x6b, 0xea, 0xe9, 0x8b, 0xe1,
            0x36, 0x83, 0xa5, 0xba, 0x4d, 0x7f, 0xb4, 0x92, 0xf0, 0xbc, 0x40, 0x25, 0x34, 0x60, 0x0d, 0xa3,
            0x18, 0xa3, 0xb4, 0xc2, 0x24, 0xbe, 0xb8, 0xfa, 0x86, 0xd3, 0xbd, 0x51, 0xe4, 0x7d, 0x04, 0x15,
            0x14, 0x14, 0xff, 0x1a, 0x8e, 0x69, 0xe6, 0xae, 0xf4, 0x79, 0xb8, 0x41, 0x09, 0x28, 0x4d, 0x94,
        },
        // IC[6] - public_amount
        .{
            0x0b, 0x18, 0x0c, 0xc9, 0xc9, 0xd9, 0xb3, 0xa3, 0x06, 0xa7, 0x25, 0x28, 0xac, 0xec, 0x51, 0xf6,
            0x1f, 0x26, 0x70, 0x11, 0x64, 0xa3, 0x6f, 0x39, 0x1f, 0xc6, 0xe7, 0x3f, 0xe0, 0xb2, 0x26, 0x4c,
            0x0c, 0x9a, 0xa0, 0x29, 0x3a, 0xb1, 0x05, 0xc5, 0xdf, 0x71, 0x0c, 0x4b, 0xed, 0xef, 0x09, 0x28,
            0xb2, 0x2c, 0xde, 0x82, 0x7d, 0xdd, 0x8e, 0xf1, 0xd5, 0x3a, 0x83, 0xf2, 0x78, 0x6c, 0xd5, 0xa3,
        },
        // IC[7] - ext_data_hash
        .{
            0x01, 0x53, 0x86, 0xbb, 0x1e, 0x31, 0x3d, 0x76, 0xce, 0x6e, 0xe1, 0xc0, 0x9b, 0x65, 0x9b, 0xcc,
            0xca, 0x31, 0xe5, 0x29, 0x94, 0xe8, 0x18, 0x2f, 0x55, 0x2f, 0x6c, 0x63, 0x71, 0x0c, 0xd1, 0x58,
            0x29, 0x90, 0xb9, 0x1e, 0xb0, 0x2e, 0xbe, 0xf4, 0x94, 0x97, 0x8e, 0x40, 0x2d, 0x16, 0x10, 0x11,
            0x30, 0x7a, 0xb7, 0x51, 0xbb, 0x12, 0x8e, 0x0a, 0xe6, 0x4e, 0x06, 0x2a, 0xf5, 0x8c, 0xa6, 0x79,
        },
    };
};

/// Verify Groth16 proof using Solana's alt_bn128 precompile
///
/// Implements the Groth16 verification equation:
///   e(-A, B) · e(α, β) · e(vk_x, γ) · e(C, δ) = 1
///
/// Where vk_x = IC[0] + Σ(public_inputs[i] * IC[i+1])
///
/// Note: Uses noinline to prevent stack frame explosion from inlining
pub noinline fn verifyGroth16(
    proof_a: [64]u8,
    proof_b: [128]u8,
    proof_c: [64]u8,
    public_inputs: [NR_PUBLIC_INPUTS][32]u8,
) bool {
    // Quick validity check - proof_a must not be zero
    if (isG1Zero(&proof_a)) return false;
    if (isG1Zero(&proof_c)) return false;

    // Step 1: Compute vk_x = IC[0] + Σ(public_inputs[i] * IC[i+1])
    const vk_x = computeVkX(&public_inputs) orelse return false;

    // Step 2: Verify pairing equation
    return verifyPairing(&proof_a, &proof_b, &proof_c, &vk_x);
}

/// Check if G1 point is zero (identity element)
fn isG1Zero(point: *const [64]u8) bool {
    for (point[0..32]) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// Compute vk_x = IC[0] + Σ(public_inputs[i] * IC[i+1])
noinline fn computeVkX(public_inputs: *const [NR_PUBLIC_INPUTS][32]u8) ?[64]u8 {
    var vk_x: [64]u8 = VERIFYING_KEY.vk_ic[0];

    for (public_inputs, 0..) |input, i| {
        // Scalar multiplication: input * IC[i+1]
        var mul_input: [96]u8 = undefined;
        @memcpy(mul_input[0..64], &VERIFYING_KEY.vk_ic[i + 1]);
        @memcpy(mul_input[64..96], &input);

        var mul_result: [64]u8 = undefined;
        sol.bn254.g1MultiplicationBE(&mul_input, &mul_result) catch return null;

        // Point addition: vk_x + mul_result
        var add_input: [128]u8 = undefined;
        @memcpy(add_input[0..64], &vk_x);
        @memcpy(add_input[64..128], &mul_result);

        sol.bn254.g1AdditionBE(&add_input, &vk_x) catch return null;
    }

    return vk_x;
}

/// Verify the pairing equation e(-A, B) · e(α, β) · e(vk_x, γ) · e(C, δ) = 1
noinline fn verifyPairing(
    proof_a: *const [64]u8,
    proof_b: *const [128]u8,
    proof_c: *const [64]u8,
    vk_x: *const [64]u8,
) bool {
    // Negate A for pairing equation
    var neg_a: [64]u8 = undefined;
    negateG1BE(proof_a, &neg_a);

    // Build pairing input incrementally to reduce stack usage
    // Using a smaller buffer and building pairs one at a time
    var pairing_input: [768]u8 = undefined;

    // Pair 1: (-A, B)
    @memcpy(pairing_input[0..64], &neg_a);
    @memcpy(pairing_input[64..192], proof_b);

    // Pair 2: (α, β)
    @memcpy(pairing_input[192..256], &VERIFYING_KEY.vk_alpha_g1);
    @memcpy(pairing_input[256..384], &VERIFYING_KEY.vk_beta_g2);

    // Pair 3: (vk_x, γ)
    @memcpy(pairing_input[384..448], vk_x);
    @memcpy(pairing_input[448..576], &VERIFYING_KEY.vk_gamma_g2);

    // Pair 4: (C, δ)
    @memcpy(pairing_input[576..640], proof_c);
    @memcpy(pairing_input[640..768], &VERIFYING_KEY.vk_delta_g2);

    // Pairing check
    return sol.bn254.pairingBE(&pairing_input) catch false;
}

/// Verify Groth16 proof directly from TransactArgs to avoid stack copy
noinline fn verifyGroth16FromArgs(args: *const TransactArgs) bool {
    // Quick validity check
    if (isG1Zero(&args.proof_a)) return false;
    if (isG1Zero(&args.proof_c)) return false;

    // Build public inputs array from args
    const public_inputs: [NR_PUBLIC_INPUTS][32]u8 = .{
        args.root,
        args.public_amount,
        args.ext_data_hash,
        args.input_nullifier1,
        args.input_nullifier2,
        args.output_commitment1,
        args.output_commitment2,
    };

    // Compute vk_x
    const vk_x = computeVkX(&public_inputs) orelse return false;

    // Verify pairing equation
    return verifyPairing(&args.proof_a, &args.proof_b, &args.proof_c, &vk_x);
}

/// Negate a G1 point (big-endian format)
/// For BN254: -P = (P.x, -P.y mod p)
fn negateG1BE(point: *const [64]u8, result: *[64]u8) void {
    // Copy x coordinate (unchanged)
    @memcpy(result[0..32], point[0..32]);

    // Negate y coordinate: -y = p - y (mod p)
    // BN254 prime p in big-endian
    const p: [32]u8 = .{
        0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
        0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
        0x28, 0x33, 0xe8, 0x48, 0x79, 0xb9, 0x70, 0x91,
        0x43, 0xe1, 0xf5, 0x93, 0xf0, 0x00, 0x00, 0x01,
    };

    // Compute p - y using big integer subtraction
    var borrow: u16 = 0;
    var y_neg: [32]u8 = undefined;
    for (0..32) |i| {
        const idx = 31 - i;
        const diff: i32 = @as(i32, p[idx]) - @as(i32, point[32 + idx]) - @as(i32, @intCast(borrow));
        if (diff < 0) {
            y_neg[idx] = @truncate(@as(u32, @intCast(diff + 256)));
            borrow = 1;
        } else {
            y_neg[idx] = @truncate(@as(u32, @intCast(diff)));
            borrow = 0;
        }
    }

    @memcpy(result[32..64], &y_neg);
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

    // 4. Verify Groth16 proof (use args directly to avoid stack copy)
    if (!verifyGroth16FromArgs(args)) {
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
