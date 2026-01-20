//! Privacy Pool Program - Zig Implementation
//!
//! A privacy pool for Solana using Groth16 ZK proofs.
//! Fully compatible with Privacy Cash protocol.
//!
//! ## Instructions
//! - initialize: Initialize SOL pool
//! - initialize_spl: Initialize SPL Token pool  
//! - update_config: Update global configuration
//! - transact: SOL deposit/withdraw/transfer with ZK proof
//! - transact_spl: SPL Token deposit/withdraw/with ZK proof

const std = @import("std");
const sol = @import("solana_program_sdk");
const anchor = @import("sol_anchor_zig");
const zero = anchor.zero_cu;
const idl = anchor.idl_zero;
const spl_token = anchor.spl.token;
const syscall_wrappers = @import("syscall_wrappers.zig");

// Increase comptime branch quota for large account structures
comptime {
    @setEvalBranchQuota(10000);
}

// ============================================================================
// Program ID
// ============================================================================

pub const PROGRAM_ID = sol.PublicKey.comptimeFromBase58("PrivZig111111111111111111111111111111111111");

// ============================================================================
// Constants (Privacy Cash compatible)
// ============================================================================

pub const MERKLE_TREE_HEIGHT: u8 = 26; // 2^26 = 67M leaves (same as Privacy Cash)
pub const ROOT_HISTORY_SIZE: usize = 100; // Same as Privacy Cash
pub const PROOF_SIZE: usize = 256;
pub const NR_PUBLIC_INPUTS: usize = 7;
pub const FEE_DENOMINATOR: u64 = 10000;

/// System Program ID
pub const SYSTEM_PROGRAM_ID = sol.PublicKey.comptimeFromBase58("11111111111111111111111111111111");

/// SPL Token Program ID
pub const TOKEN_PROGRAM_ID = sol.PublicKey.comptimeFromBase58("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");

// Pre-computed Poseidon zero hashes for Merkle tree (height 26)
// zeros[0] = 0, zeros[i] = poseidon(zeros[i-1], zeros[i-1])
pub const ZERO_HASHES: [MERKLE_TREE_HEIGHT + 1][32]u8 = .{
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, // Level 0
    .{ 0x20, 0x98, 0xf5, 0xfb, 0x9e, 0x23, 0x9e, 0xab, 0x3c, 0xea, 0xc3, 0xf2, 0x7b, 0x81, 0xe4, 0x81, 0xdc, 0x31, 0x24, 0xd5, 0x5f, 0xfe, 0xd5, 0x23, 0xa8, 0x39, 0xee, 0x84, 0x46, 0xb6, 0x48, 0x64 }, // Level 1
    .{ 0x10, 0x69, 0x67, 0x3d, 0xcd, 0xb1, 0x22, 0x63, 0xdf, 0x30, 0x1a, 0x6f, 0xf5, 0x84, 0xa7, 0xec, 0x26, 0x1a, 0x44, 0xcb, 0x9d, 0xc6, 0x8d, 0xf0, 0x67, 0xa4, 0x77, 0x44, 0x60, 0xb1, 0xf1, 0xe1 }, // Level 2
    .{ 0x18, 0xf4, 0x33, 0x31, 0x53, 0x7e, 0xe2, 0xaf, 0x2e, 0x3d, 0x75, 0x8d, 0x50, 0xf7, 0x21, 0x06, 0x46, 0x7c, 0x6e, 0xea, 0x50, 0x37, 0x1d, 0xd5, 0x28, 0xd5, 0x7e, 0xb2, 0xb8, 0x56, 0xd2, 0x38 }, // Level 3
    .{ 0x07, 0xf9, 0xd8, 0x37, 0xcb, 0x17, 0xb0, 0xd3, 0x63, 0x20, 0xff, 0xe9, 0x3b, 0xa5, 0x23, 0x45, 0xf1, 0xb7, 0x28, 0x57, 0x1a, 0x56, 0x82, 0x65, 0xca, 0xac, 0x97, 0x55, 0x9d, 0xbc, 0x95, 0x2a }, // Level 4
    .{ 0x2b, 0x94, 0xcf, 0x5e, 0x87, 0x46, 0xb3, 0xf5, 0xc9, 0x63, 0x1f, 0x4c, 0x5d, 0xf3, 0x29, 0x07, 0xa6, 0x99, 0xc5, 0x8c, 0x94, 0xb2, 0xad, 0x4d, 0x7b, 0x5c, 0xec, 0x16, 0x39, 0x18, 0x3f, 0x55 }, // Level 5
    .{ 0x2d, 0xee, 0x93, 0xc5, 0xa6, 0x66, 0x45, 0x96, 0x46, 0xea, 0x7d, 0x22, 0xcc, 0xa9, 0xe1, 0xbc, 0xfe, 0xd7, 0x1e, 0x69, 0x51, 0xb9, 0x53, 0x61, 0x1d, 0x11, 0xdd, 0xa3, 0x2e, 0xa0, 0x9d, 0x78 }, // Level 6
    .{ 0x07, 0x82, 0x95, 0xe5, 0xa2, 0x2b, 0x84, 0xe9, 0x82, 0xcf, 0x60, 0x1e, 0xb6, 0x39, 0x59, 0x7b, 0x8b, 0x05, 0x15, 0xa8, 0x8c, 0xb5, 0xac, 0x7f, 0xa8, 0xa4, 0xaa, 0xbe, 0x3c, 0x87, 0x34, 0x9d }, // Level 7
    .{ 0x2f, 0xa5, 0xe5, 0xf1, 0x8f, 0x60, 0x27, 0xa6, 0x50, 0x1b, 0xec, 0x86, 0x45, 0x64, 0x47, 0x2a, 0x61, 0x6b, 0x2e, 0x27, 0x4a, 0x41, 0x21, 0x1a, 0x44, 0x4c, 0xbe, 0x3a, 0x99, 0xf3, 0xcc, 0x61 }, // Level 8
    .{ 0x0e, 0x88, 0x43, 0x76, 0xd0, 0xd8, 0xfd, 0x21, 0xec, 0xb7, 0x80, 0x38, 0x9e, 0x94, 0x1f, 0x66, 0xe4, 0x5e, 0x7a, 0xcc, 0xe3, 0xe2, 0x28, 0xab, 0x3e, 0x21, 0x56, 0xa6, 0x14, 0xfc, 0xd7, 0x47 }, // Level 9
    .{ 0x1b, 0x72, 0x01, 0xda, 0x72, 0x49, 0x4f, 0x1e, 0x28, 0x71, 0x7a, 0xd1, 0xa5, 0x2e, 0xb4, 0x69, 0xf9, 0x58, 0x92, 0xf9, 0x57, 0x71, 0x35, 0x33, 0xde, 0x61, 0x75, 0xe5, 0xda, 0x19, 0x0a, 0xf2 }, // Level 10
    .{ 0x1f, 0x8d, 0x88, 0x22, 0x72, 0x5e, 0x36, 0x38, 0x52, 0x00, 0xc0, 0xb2, 0x01, 0x24, 0x98, 0x19, 0xa6, 0xe6, 0xe1, 0xe4, 0x65, 0x08, 0x08, 0xb5, 0xbe, 0xbc, 0x6b, 0xfa, 0xce, 0x7d, 0x76, 0x36 }, // Level 11
    .{ 0x2c, 0x5d, 0x82, 0xf6, 0x6c, 0x91, 0x4b, 0xaf, 0xb9, 0x70, 0x15, 0x89, 0xba, 0x8c, 0xfc, 0xfb, 0x61, 0x62, 0xb0, 0xa1, 0x2a, 0xcf, 0x88, 0xa8, 0xd0, 0x87, 0x9a, 0x04, 0x71, 0xb5, 0xf8, 0x5a }, // Level 12
    .{ 0x14, 0xc5, 0x41, 0x48, 0xa0, 0x94, 0x0b, 0xb8, 0x20, 0x95, 0x7f, 0x5a, 0xdf, 0x3f, 0xa1, 0x13, 0x4e, 0xf5, 0xc4, 0xaa, 0xa1, 0x13, 0xf4, 0x64, 0x64, 0x58, 0xf2, 0x70, 0xe0, 0xbf, 0xbf, 0xd0 }, // Level 13
    .{ 0x19, 0x0d, 0x33, 0xb1, 0x2f, 0x98, 0x6f, 0x96, 0x1e, 0x10, 0xc0, 0xee, 0x44, 0xd8, 0xb9, 0xaf, 0x11, 0xbe, 0x25, 0x58, 0x8c, 0xad, 0x89, 0xd4, 0x16, 0x11, 0x8e, 0x4b, 0xf4, 0xeb, 0xe8, 0x0c }, // Level 14
    .{ 0x22, 0xf9, 0x8a, 0xa9, 0xce, 0x70, 0x41, 0x52, 0xac, 0x17, 0x35, 0x49, 0x14, 0xad, 0x73, 0xed, 0x11, 0x67, 0xae, 0x65, 0x96, 0xaf, 0x51, 0x0a, 0xa5, 0xb3, 0x64, 0x93, 0x25, 0xe0, 0x6c, 0x92 }, // Level 15
    .{ 0x2a, 0x7c, 0x7c, 0x9b, 0x6c, 0xe5, 0x88, 0x0b, 0x9f, 0x6f, 0x22, 0x8d, 0x72, 0xbf, 0x6a, 0x57, 0x5a, 0x52, 0x6f, 0x29, 0xc6, 0x6e, 0xcc, 0xee, 0xf8, 0xb7, 0x53, 0xd3, 0x8b, 0xba, 0x73, 0x23 }, // Level 16
    .{ 0x2e, 0x81, 0x86, 0xe5, 0x58, 0x69, 0x8e, 0xc1, 0xc6, 0x7a, 0xf9, 0xc1, 0x4d, 0x46, 0x3f, 0xfc, 0x47, 0x00, 0x43, 0xc9, 0xc2, 0x98, 0x8b, 0x95, 0x4d, 0x75, 0xdd, 0x64, 0x3f, 0x36, 0xb9, 0x92 }, // Level 17
    .{ 0x0f, 0x57, 0xc5, 0x57, 0x1e, 0x9a, 0x4e, 0xab, 0x49, 0xe2, 0xc8, 0xcf, 0x05, 0x0d, 0xae, 0x94, 0x8a, 0xef, 0x6e, 0xad, 0x64, 0x73, 0x92, 0x27, 0x35, 0x46, 0x24, 0x9d, 0x1c, 0x1f, 0xf1, 0x0f }, // Level 18
    .{ 0x18, 0x30, 0xee, 0x67, 0xb5, 0xfb, 0x55, 0x4a, 0xd5, 0xf6, 0x3d, 0x43, 0x88, 0x80, 0x0e, 0x1c, 0xfe, 0x78, 0xe3, 0x10, 0x69, 0x7d, 0x46, 0xe4, 0x3c, 0x9c, 0xe3, 0x61, 0x34, 0xf7, 0x2c, 0xca }, // Level 19
    .{ 0x21, 0x34, 0xe7, 0x6a, 0xc5, 0xd2, 0x1a, 0xab, 0x18, 0x6c, 0x2b, 0xe1, 0xdd, 0x8f, 0x84, 0xee, 0x88, 0x0a, 0x1e, 0x46, 0xea, 0xf7, 0x12, 0xf9, 0xd3, 0x71, 0xb6, 0xdf, 0x22, 0x19, 0x1f, 0x3e }, // Level 20
    .{ 0x19, 0xdf, 0x90, 0xec, 0x84, 0x4e, 0xbc, 0x4f, 0xfe, 0xeb, 0xd8, 0x66, 0xf3, 0x38, 0x59, 0xb0, 0xc0, 0x51, 0xd8, 0xc9, 0x58, 0xee, 0x3a, 0xa8, 0x8f, 0x8f, 0x8d, 0xf3, 0xdb, 0x91, 0xa5, 0xb1 }, // Level 21
    .{ 0x18, 0xcc, 0xa2, 0xa6, 0x6b, 0x5c, 0x07, 0x87, 0x98, 0x1e, 0x69, 0xae, 0xfd, 0x84, 0x85, 0x2d, 0x74, 0xaf, 0x0e, 0x93, 0xef, 0x49, 0x12, 0xb4, 0x64, 0x8c, 0x05, 0xf7, 0x22, 0xef, 0xe5, 0x2b }, // Level 22
    .{ 0x23, 0x88, 0x90, 0x94, 0x15, 0x23, 0x0d, 0x1b, 0x4d, 0x13, 0x04, 0xd2, 0xd5, 0x4f, 0x47, 0x3a, 0x62, 0x83, 0x38, 0xf2, 0xef, 0xad, 0x83, 0xfa, 0xdf, 0x05, 0x64, 0x45, 0x49, 0xd2, 0x53, 0x8d }, // Level 23
    .{ 0x27, 0x17, 0x1f, 0xb4, 0xa9, 0x7b, 0x6c, 0xc0, 0xe9, 0xe8, 0xf5, 0x43, 0xb5, 0x29, 0x4d, 0xe8, 0x66, 0xa2, 0xaf, 0x2c, 0x9c, 0x8d, 0x0b, 0x1d, 0x96, 0xe6, 0x73, 0xe4, 0x52, 0x9e, 0xd5, 0x40 }, // Level 24
    .{ 0x2f, 0xf6, 0x65, 0x05, 0x40, 0xf6, 0x29, 0xfd, 0x57, 0x11, 0xa0, 0xbc, 0x74, 0xfc, 0x0d, 0x28, 0xdc, 0xb2, 0x30, 0xb9, 0x39, 0x25, 0x83, 0xe5, 0xf8, 0xd5, 0x96, 0x96, 0xdd, 0xe6, 0xae, 0x21 }, // Level 25
    .{ 0x12, 0x0c, 0x58, 0xf1, 0x43, 0xd4, 0x91, 0xe9, 0x59, 0x02, 0xf7, 0xf5, 0x27, 0x77, 0x78, 0xa2, 0xe0, 0xad, 0x51, 0x68, 0xf6, 0xad, 0xd7, 0x56, 0x69, 0x93, 0x26, 0x30, 0xce, 0x61, 0x15, 0x18 }, // Level 26 (empty tree root)
};

pub inline fn zeroHash(level: u8) [32]u8 {
    return ZERO_HASHES[level];
}

// ============================================================================
// Account Structures
// ============================================================================

/// Merkle tree account for tracking commitments
pub const TreeAccount = extern struct {
    authority: sol.PublicKey,
    next_index: u64,
    root_index: u64,
    bump: u8,
    max_deposit_amount: u64,
    height: u8,
    root_history_size: u8,
    _padding: [5]u8,
    root_history: [ROOT_HISTORY_SIZE][32]u8,
    filled_subtrees: [MERKLE_TREE_HEIGHT][32]u8,

    pub fn isKnownRoot(self: *const TreeAccount, root: [32]u8) bool {
        var is_zero = true;
        var j: usize = 0;
        while (j < 32) : (j += 1) {
            if (root[j] != 0) {
                is_zero = false;
                break;
            }
        }
        if (is_zero) return false;

        var i: usize = 0;
        while (i < ROOT_HISTORY_SIZE) : (i += 1) {
            var matches = true;
            var k: usize = 0;
            while (k < 32) : (k += 1) {
                if (self.root_history[i][k] != root[k]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }
};

/// Global configuration for fees
pub const GlobalConfig = extern struct {
    authority: sol.PublicKey,
    fee_recipient: sol.PublicKey, // Added: fee recipient address
    deposit_fee_rate: u16,
    withdrawal_fee_rate: u16,
    fee_error_margin: u16,
    bump: u8,
    _padding: [1]u8,
};

/// Nullifier account to prevent double-spending
pub const NullifierAccount = extern struct {
    is_used: u8,
    _padding: [31]u8,
};

/// SPL Token pool account
pub const TokenPoolAccount = extern struct {
    authority: sol.PublicKey,
    mint: sol.PublicKey,
    vault: sol.PublicKey,
    bump: u8,
    _padding: [7]u8,
};

// ============================================================================
// Poseidon Hash
// ============================================================================

pub fn poseidonHash2(left: [32]u8, right: [32]u8) [32]u8 {
    // Solana Poseidon syscall expects: vals = pointer to array of Rust slices
    // A Rust slice (&[u8]) in C ABI is { ptr: *const u8, len: usize }
    const Slice = extern struct {
        ptr: [*]const u8,
        len: u64,
    };
    
    const inputs: [2]Slice = .{
        .{ .ptr = &left, .len = 32 },
        .{ .ptr = &right, .len = 32 },
    };
    
    var result: [32]u8 = undefined;
    // params=0 (Bn254X5), endianness=0 (BigEndian), vals_len=2 (number of inputs)
    const ret = syscall_wrappers.poseidon(0, 0, @ptrCast(&inputs), 2, &result);
    if (ret != 0) return [_]u8{0} ** 32;
    return result;
}

// ============================================================================
// Merkle Tree Operations
// ============================================================================

pub fn insertLeaf(tree: *TreeAccount, leaf: [32]u8) ![32]u8 {
    const index = tree.next_index;
    const height: u8 = tree.height;
    const capacity: u64 = @as(u64, 1) << @as(u6, @truncate(height));

    if (index >= capacity) return error.TreeFull;

    var current = leaf;
    var current_index = index;

    var level: u8 = 0;
    while (level < height) : (level += 1) {
        if (current_index % 2 == 0) {
            tree.filled_subtrees[level] = current;
            current = poseidonHash2(current, zeroHash(level));
        } else {
            current = poseidonHash2(tree.filled_subtrees[level], current);
        }
        current_index /= 2;
    }

    tree.root_index = (tree.root_index + 1) % ROOT_HISTORY_SIZE;
    tree.root_history[tree.root_index] = current;
    tree.next_index += 1;

    return current;
}

// ============================================================================
// Event Definitions (Privacy Cash compatible)
// ============================================================================

/// CommitmentData event - emitted when a new commitment is added to the Merkle tree
const CommitmentDataEvent = struct {
    index: u64,
    commitment: [32]u8,
};

/// Emit CommitmentData event using Anchor event format
fn emitCommitmentEvent(index: u64, commitment: [32]u8) void {
    anchor.event.emitEvent(CommitmentDataEvent, .{
        .index = index,
        .commitment = commitment,
    });
}

// ============================================================================
// Groth16 Verification Key (Privacy Cash compatible)
// ============================================================================

pub const VERIFYING_KEY = struct {
    pub const vk_alpha_g1: [64]u8 = .{
        45, 77, 154, 167, 227, 2, 217, 223, 65, 116, 157, 85, 7, 148, 157, 5,
        219, 234, 51, 251, 177, 108, 100, 59, 34, 245, 153, 162, 190, 109, 242, 226,
        20, 190, 221, 80, 60, 55, 206, 176, 97, 216, 236, 96, 32, 159, 227, 69,
        206, 137, 131, 10, 25, 35, 3, 1, 240, 118, 202, 255, 0, 77, 25, 38,
    };

    pub const vk_beta_g2: [128]u8 = .{
        9, 103, 3, 47, 203, 247, 118, 209, 175, 201, 133, 248, 136, 119, 241, 130,
        211, 132, 128, 166, 83, 242, 222, 202, 169, 121, 76, 188, 59, 243, 6, 12,
        14, 24, 120, 71, 173, 76, 121, 131, 116, 208, 214, 115, 43, 245, 1, 132,
        125, 214, 139, 192, 224, 113, 36, 30, 2, 19, 188, 127, 193, 61, 183, 171,
        48, 76, 251, 209, 224, 138, 112, 74, 153, 245, 232, 71, 217, 63, 140, 60,
        170, 253, 222, 196, 107, 122, 13, 55, 157, 166, 154, 77, 17, 35, 70, 167,
        23, 57, 193, 177, 164, 87, 168, 199, 49, 49, 35, 210, 77, 47, 145, 146,
        248, 150, 183, 198, 62, 234, 5, 169, 213, 127, 6, 84, 122, 208, 206, 200,
    };

    pub const vk_gamma_g2: [128]u8 = .{
        25, 142, 147, 147, 146, 13, 72, 58, 114, 96, 191, 183, 49, 251, 93, 37,
        241, 170, 73, 51, 53, 169, 231, 18, 151, 228, 133, 183, 174, 243, 18, 194,
        24, 0, 222, 239, 18, 31, 30, 118, 66, 106, 0, 102, 94, 92, 68, 121,
        103, 67, 34, 212, 247, 94, 218, 221, 70, 222, 189, 92, 217, 146, 246, 237,
        9, 6, 137, 208, 88, 95, 240, 117, 236, 158, 153, 173, 105, 12, 51, 149,
        188, 75, 49, 51, 112, 179, 142, 243, 85, 172, 218, 220, 209, 34, 151, 91,
        18, 200, 94, 165, 219, 140, 109, 235, 74, 171, 113, 128, 141, 203, 64, 143,
        227, 209, 231, 105, 12, 67, 211, 123, 76, 230, 204, 1, 102, 250, 125, 170,
    };

    pub const vk_delta_g2: [128]u8 = .{
        25, 252, 204, 73, 0, 218, 132, 40, 192, 175, 106, 179, 247, 34, 6, 163,
        111, 68, 46, 211, 76, 146, 16, 158, 28, 23, 146, 254, 157, 94, 7, 92,
        34, 128, 9, 143, 49, 11, 128, 172, 203, 141, 109, 166, 180, 82, 110, 179,
        223, 71, 56, 138, 77, 154, 73, 160, 146, 198, 203, 125, 196, 135, 167, 56,
        21, 152, 106, 224, 184, 3, 47, 85, 250, 118, 220, 185, 175, 242, 111, 30,
        40, 24, 69, 173, 252, 13, 109, 1, 241, 162, 122, 76, 24, 38, 72, 88,
        45, 118, 91, 197, 236, 236, 152, 29, 29, 233, 108, 250, 155, 255, 230, 156,
        182, 159, 1, 3, 41, 60, 40, 136, 181, 220, 23, 150, 130, 211, 23, 83,
    };

    pub const vk_ic: [8][64]u8 = .{
        .{ 0x23, 0x79, 0x17, 0xa2, 0x20, 0x65, 0xf7, 0x73, 0xb1, 0xc7, 0x32, 0x9e, 0x03, 0x3c, 0xbc, 0x5f, 0x5b, 0x1d, 0x79, 0xd2, 0x35, 0x9b, 0xf5, 0xe2, 0xcb, 0xf5, 0xba, 0xa7, 0x27, 0x20, 0xa0, 0xca, 0x16, 0x16, 0xa8, 0xa0, 0x7d, 0x2d, 0x38, 0x2d, 0x84, 0xd6, 0x14, 0xc6, 0x4c, 0x51, 0x02, 0x96, 0x00, 0x3d, 0x56, 0x82, 0x69, 0xaa, 0x8d, 0xf4, 0x0d, 0xb4, 0x51, 0x4f, 0x12, 0xa6, 0x81, 0x81 },
        .{ 0x0d, 0x94, 0x3f, 0xea, 0xb9, 0x2a, 0x03, 0x9f, 0x7f, 0x18, 0xf0, 0xc8, 0x48, 0x18, 0xb0, 0x07, 0xb5, 0xd7, 0xd4, 0x34, 0x0d, 0xa0, 0xac, 0xb6, 0xb1, 0x16, 0xeb, 0x04, 0xad, 0xe5, 0x19, 0x6c, 0x2e, 0x3d, 0xe9, 0xb8, 0xb5, 0x98, 0x84, 0x67, 0xfc, 0x64, 0xe5, 0x90, 0xd9, 0x24, 0x27, 0xfe, 0x43, 0xed, 0x46, 0xd6, 0xc0, 0xe7, 0x8c, 0x56, 0x71, 0x28, 0x0b, 0x58, 0x0c, 0x96, 0x9d, 0xe2 },
        .{ 0x1a, 0x69, 0x96, 0xcc, 0xb2, 0xca, 0x1a, 0x3e, 0x27, 0xb2, 0xb3, 0xe1, 0x85, 0x8c, 0x8a, 0x28, 0x3c, 0xbb, 0x63, 0x39, 0xed, 0x07, 0xcb, 0x9f, 0xfb, 0x67, 0x2e, 0xcf, 0xdb, 0xba, 0x13, 0x40, 0x00, 0x2a, 0x49, 0x05, 0x4c, 0x30, 0x73, 0x50, 0x60, 0x1d, 0xc5, 0xd5, 0xe4, 0xf0, 0x07, 0x90, 0x8c, 0x03, 0x7f, 0x59, 0x57, 0xf7, 0x62, 0x99, 0xae, 0x51, 0x07, 0x9e, 0xb7, 0x50, 0x8b, 0x93 },
        .{ 0x06, 0xf9, 0x58, 0x68, 0x38, 0x4a, 0x90, 0x88, 0x81, 0xb0, 0x46, 0xd8, 0x12, 0x93, 0x4e, 0x8d, 0x18, 0x5d, 0x5f, 0xf2, 0x44, 0x31, 0xd7, 0x98, 0xf6, 0x6e, 0x97, 0xf1, 0xe4, 0x3b, 0xe6, 0xbb, 0x1d, 0x38, 0xba, 0xd2, 0xc8, 0xbe, 0x5d, 0x40, 0x6e, 0x00, 0x37, 0x69, 0xa6, 0x68, 0xd0, 0x2e, 0x52, 0x51, 0x92, 0x88, 0xb3, 0x63, 0x68, 0xe8, 0x63, 0xf8, 0xa2, 0x89, 0x15, 0xd9, 0xdc, 0x4d },
        .{ 0x22, 0xa3, 0xaa, 0x5b, 0xfe, 0xd7, 0xdc, 0xaf, 0x47, 0x43, 0x38, 0x2b, 0xb2, 0x30, 0x5c, 0x07, 0xaa, 0x7c, 0xc9, 0xe8, 0xcf, 0xca, 0x86, 0x50, 0x7b, 0x1f, 0x1a, 0xec, 0x4c, 0xaf, 0xba, 0x9b, 0x2e, 0xfd, 0xec, 0xaa, 0x0c, 0xf8, 0x1e, 0x7f, 0x33, 0x88, 0x64, 0x33, 0x22, 0x07, 0xda, 0x15, 0x85, 0x33, 0x94, 0xeb, 0x5c, 0xd2, 0x75, 0x86, 0x79, 0x4e, 0xa6, 0x5a, 0x0a, 0xc2, 0xc1, 0x94 },
        .{ 0x24, 0xb4, 0x52, 0xce, 0xe7, 0xc3, 0x56, 0x29, 0x6a, 0x91, 0x15, 0x6b, 0xea, 0xe9, 0x8b, 0xe1, 0x36, 0x83, 0xa5, 0xba, 0x4d, 0x7f, 0xb4, 0x92, 0xf0, 0xbc, 0x40, 0x25, 0x34, 0x60, 0x0d, 0xa3, 0x18, 0xa3, 0xb4, 0xc2, 0x24, 0xbe, 0xb8, 0xfa, 0x86, 0xd3, 0xbd, 0x51, 0xe4, 0x7d, 0x04, 0x15, 0x14, 0x14, 0xff, 0x1a, 0x8e, 0x69, 0xe6, 0xae, 0xf4, 0x79, 0xb8, 0x41, 0x09, 0x28, 0x4d, 0x94 },
        .{ 0x0b, 0x18, 0x0c, 0xc9, 0xc9, 0xd9, 0xb3, 0xa3, 0x06, 0xa7, 0x25, 0x28, 0xac, 0xec, 0x51, 0xf6, 0x1f, 0x26, 0x70, 0x11, 0x64, 0xa3, 0x6f, 0x39, 0x1f, 0xc6, 0xe7, 0x3f, 0xe0, 0xb2, 0x26, 0x4c, 0x0c, 0x9a, 0xa0, 0x29, 0x3a, 0xb1, 0x05, 0xc5, 0xdf, 0x71, 0x0c, 0x4b, 0xed, 0xef, 0x09, 0x28, 0xb2, 0x2c, 0xde, 0x82, 0x7d, 0xdd, 0x8e, 0xf1, 0xd5, 0x3a, 0x83, 0xf2, 0x78, 0x6c, 0xd5, 0xa3 },
        .{ 0x01, 0x53, 0x86, 0xbb, 0x1e, 0x31, 0x3d, 0x76, 0xce, 0x6e, 0xe1, 0xc0, 0x9b, 0x65, 0x9b, 0xcc, 0xca, 0x31, 0xe5, 0x29, 0x94, 0xe8, 0x18, 0x2f, 0x55, 0x2f, 0x6c, 0x63, 0x71, 0x0c, 0xd1, 0x58, 0x29, 0x90, 0xb9, 0x1e, 0xb0, 0x2e, 0xbe, 0xf4, 0x94, 0x97, 0x8e, 0x40, 0x2d, 0x16, 0x10, 0x11, 0x30, 0x7a, 0xb7, 0x51, 0xbb, 0x12, 0x8e, 0x0a, 0xe6, 0x4e, 0x06, 0x2a, 0xf5, 0x8c, 0xa6, 0x79 },
    };
};

// ============================================================================
// Account Definitions
// ============================================================================

// Initialize accounts - using init constraint to create accounts via CPI
const InitializeAccounts = struct {
    tree_account: zero.Account(TreeAccount, .{ .writable = true, .init = true, .payer = "authority" }),
    global_config: zero.Account(GlobalConfig, .{ .writable = true, .init = true, .payer = "authority" }),
    authority: zero.Signer(0),
    system_program: zero.Program(SYSTEM_PROGRAM_ID),
};

const UpdateConfigAccounts = struct {
    global_config: zero.Account(GlobalConfig, .{ .writable = true }),
    authority: zero.Signer(0),
};

const InitializeSplAccounts = struct {
    tree_account: zero.Account(TreeAccount, .{ .writable = true }),
    token_pool: zero.Account(TokenPoolAccount, .{ .writable = true }),
    authority: zero.Signer(0),
};

/// SOL transact accounts - includes fee recipient for fee transfers
const TransactAccounts = struct {
    tree_account: zero.Account(TreeAccount, .{ .writable = true }),
    /// Nullifier PDA accounts - created if not exists, fail if already used
    nullifier1: zero.Mut(0),
    nullifier2: zero.Mut(0),
    global_config: zero.Account(GlobalConfig, .{}),
    /// Pool vault PDA that holds SOL
    pool_vault: zero.Mut(0),
    /// Signer account (payer for tx fees and nullifier rent, can be relayer)
    signer: zero.Signer(0),
    /// Recipient account (for withdrawals) - does NOT need to sign!
    recipient: zero.Mut(0),
    /// Fee recipient account
    fee_recipient: zero.Mut(0),
    /// System program for creating nullifier accounts
    system_program: zero.Program(SYSTEM_PROGRAM_ID),
};

/// SPL Token transact accounts
const TransactSplAccounts = struct {
    tree_account: zero.Account(TreeAccount, .{ .writable = true }),
    token_pool: zero.Account(TokenPoolAccount, .{}),
    nullifier1: zero.Mut(0),
    nullifier2: zero.Mut(0),
    global_config: zero.Account(GlobalConfig, .{}),
    /// User's token account
    user_token_account: zero.Mut(0),
    /// Pool's vault token account
    vault_token_account: zero.Mut(0),
    /// User (signer for deposits)
    user: zero.Signer(0),
    /// Vault authority PDA (for withdrawals)
    vault_authority: zero.Readonly(0),
    /// Fee recipient token account
    fee_recipient_ata: zero.Mut(0),
    /// System program for creating nullifier accounts  
    system_program: zero.Program(SYSTEM_PROGRAM_ID),
};

// ============================================================================
// Arguments
// ============================================================================

const InitializeArgs = extern struct {
    max_deposit_amount: u64,
    fee_recipient: sol.PublicKey,
};

const UpdateConfigArgs = extern struct {
    deposit_fee_rate: u16,
    withdrawal_fee_rate: u16,
    fee_error_margin: u16,
    fee_recipient: sol.PublicKey,
};

const InitializeSplArgs = extern struct {
    max_deposit_amount: u64,
};

/// Proof structure (256 bytes)
const Proof = extern struct {
    a: [64]u8,  // G1 point
    b: [128]u8, // G2 point
    c: [64]u8,  // G1 point
};

/// Transaction arguments (Privacy Cash compatible)
const TransactArgs = extern struct {
    proof: Proof,
    root: [32]u8,
    input_nullifier1: [32]u8,
    input_nullifier2: [32]u8,
    output_commitment1: [32]u8,
    output_commitment2: [32]u8,
    public_amount: i64,
    ext_data_hash: [32]u8,
};

// ============================================================================
// Transfer Helpers
// ============================================================================

/// Transfer SOL by directly manipulating lamports
fn transferLamports(
    from_lamports: *u64,
    to_lamports: *u64,
    amount: u64,
) !void {
    if (from_lamports.* < amount) return error.InsufficientFunds;
    from_lamports.* -= amount;
    to_lamports.* += amount;
}

const AccountParam = sol.account.Account.Param;
const Instruction = sol.instruction.Instruction;
const AccountInfo = sol.account.Account.Info;

/// Transfer SPL Tokens using Token Program CPI
fn transferTokensCpi(
    source: AccountInfo,
    destination: AccountInfo,
    authority: AccountInfo,
    amount: u64,
) !void {
    var data: [9]u8 = undefined;
    data[0] = 3; // Transfer instruction
    std.mem.writeInt(u64, data[1..9], amount, .little);

    const account_params = [_]AccountParam{
        .{ .id = source.id, .is_writable = true, .is_signer = false },
        .{ .id = destination.id, .is_writable = true, .is_signer = false },
        .{ .id = authority.id, .is_writable = false, .is_signer = true },
    };

    const ix = Instruction.from(.{
        .program_id = &TOKEN_PROGRAM_ID,
        .accounts = &account_params,
        .data = &data,
    });

    const account_infos = [_]AccountInfo{ source, destination, authority };

    if (ix.invoke(&account_infos)) |_| {
        return error.TokenTransferFailed;
    }
}

/// Transfer SPL Tokens from PDA using Token Program CPI with signer seeds
fn transferTokensFromPdaCpi(
    source: AccountInfo,
    destination: AccountInfo,
    authority_pda: AccountInfo,
    amount: u64,
    seeds: []const []const u8,
) !void {
    var data: [9]u8 = undefined;
    data[0] = 3; // Transfer instruction
    std.mem.writeInt(u64, data[1..9], amount, .little);

    const account_params = [_]AccountParam{
        .{ .id = source.id, .is_writable = true, .is_signer = false },
        .{ .id = destination.id, .is_writable = true, .is_signer = false },
        .{ .id = authority_pda.id, .is_writable = false, .is_signer = true },
    };

    const ix = Instruction.from(.{
        .program_id = &TOKEN_PROGRAM_ID,
        .accounts = &account_params,
        .data = &data,
    });

    const account_infos = [_]AccountInfo{ source, destination, authority_pda };

    var signer_seeds: [1][]const []const u8 = .{seeds};

    if (ix.invokeSigned(&account_infos, &signer_seeds)) |_| {
        return error.TokenTransferFailed;
    }
}

// ============================================================================
// BN254 Operations
// ============================================================================

// BN254 operation codes (big-endian input)
const BN254_ADD: u64 = 0;      // G1 addition
const BN254_MUL: u64 = 2;      // G1 scalar multiplication  
const BN254_PAIRING: u64 = 3;  // Pairing check

fn g1Add(a: [64]u8, b: [64]u8) ![64]u8 {
    var input: [128]u8 = undefined;
    @memcpy(input[0..64], &a);
    @memcpy(input[64..128], &b);

    var result: [64]u8 = undefined;
    const ret = syscall_wrappers.altBn128GroupOp(BN254_ADD, &input, 128, &result);
    if (ret != 0) return error.G1AddFailed;
    return result;
}

fn g1Mul(point: [64]u8, scalar: [32]u8) ![64]u8 {
    var input: [96]u8 = undefined;
    @memcpy(input[0..64], &point);
    @memcpy(input[64..96], &scalar);

    var result: [64]u8 = undefined;
    const ret = syscall_wrappers.altBn128GroupOp(BN254_MUL, &input, 96, &result);
    if (ret != 0) return error.G1MulFailed;
    return result;
}

/// BN254 scalar field modulus (r): 21888242871839275222246405745257275088548364400416034343698204186575808495617
/// This is SNARK_FIELD_SIZE used in Tornado Cash / Privacy Cash
const FIELD_SIZE: [32]u8 = .{
    0x30, 0x64, 0x4E, 0x72, 0xE1, 0x31, 0xA0, 0x29,
    0xB8, 0x50, 0x45, 0xB6, 0x81, 0x81, 0x58, 0x5D,
    0x28, 0x33, 0xE8, 0x48, 0x79, 0xB9, 0x70, 0x91,
    0x43, 0xE1, 0xF5, 0x93, 0xF0, 0x00, 0x00, 0x01,
};

fn i64ToFieldElement(value: i64) [32]u8 {
    // Convert i64 to 32-byte big-endian field element in BN254 scalar field
    var result: [32]u8 = [_]u8{0} ** 32;
    if (value >= 0) {
        const u_value: u64 = @intCast(value);
        // Big-endian: value goes at the END of the array
        std.mem.writeInt(u64, result[24..32], u_value, .big);
    } else {
        // Negative: compute FIELD_SIZE - |value| mod FIELD_SIZE
        // For small negatives (which is our case), this is FIELD_SIZE + value
        const abs_value: u64 = @intCast(-value);
        
        // Start with FIELD_SIZE
        var field: [32]u8 = FIELD_SIZE;
        
        // Subtract abs_value from field (big-endian subtraction)
        var borrow: u64 = abs_value;
        var i: usize = 32;
        while (i > 0) : (i -= 1) {
            const idx = i - 1;
            const byte_val: u64 = field[idx];
            if (byte_val >= borrow) {
                field[idx] = @truncate(byte_val - borrow);
                borrow = 0;
                break;
            } else {
                field[idx] = @truncate(256 + byte_val - (borrow % 256));
                borrow = (borrow / 256) + 1;
            }
        }
        
        result = field;
    }
    return result;
}

fn verifyGroth16Proof(
    proof: Proof,
    public_inputs: [NR_PUBLIC_INPUTS][32]u8,
) !bool {
    // Prepare public inputs: vk_x = vk_ic[0] + sum(public_inputs[i] * vk_ic[i+1])
    var vk_x = VERIFYING_KEY.vk_ic[0];

    var i: usize = 0;
    while (i < NR_PUBLIC_INPUTS) : (i += 1) {
        const term = try g1Mul(VERIFYING_KEY.vk_ic[i + 1], public_inputs[i]);
        vk_x = try g1Add(vk_x, term);
    }

    // Pairing check: e(A, B) * e(vk_x, gamma) * e(C, delta) * e(alpha, beta) = 1
    // Rust SDK uses order: [A, B, prepared, gamma, C, delta, alpha, beta]
    // Note: proof.a should already be negated by the client (like privacy-cash does)
    var pairing_input: [768]u8 = undefined;

    @memcpy(pairing_input[0..64], &proof.a);           // proof_a (already negated by client)
    @memcpy(pairing_input[64..192], &proof.b);         // proof_b
    @memcpy(pairing_input[192..256], &vk_x);           // prepared public inputs
    @memcpy(pairing_input[256..384], &VERIFYING_KEY.vk_gamma_g2);
    @memcpy(pairing_input[384..448], &proof.c);        // proof_c
    @memcpy(pairing_input[448..576], &VERIFYING_KEY.vk_delta_g2);
    @memcpy(pairing_input[576..640], &VERIFYING_KEY.vk_alpha_g1);
    @memcpy(pairing_input[640..768], &VERIFYING_KEY.vk_beta_g2);

    // Call pairing syscall
    var pairing_result: [32]u8 = undefined;
    const ret = syscall_wrappers.altBn128GroupOp(BN254_PAIRING, &pairing_input, 768, &pairing_result);
    if (ret != 0) return error.PairingFailed;

    // Check if result is 1 (pairing succeeded)
    var is_one = (pairing_result[31] == 1);
    var j: usize = 0;
    while (j < 31) : (j += 1) {
        if (pairing_result[j] != 0) {
            is_one = false;
            break;
        }
    }

    return is_one;
}

// ============================================================================
// Instruction Handlers
// ============================================================================

fn initializeHandler(ctx: zero.Ctx(InitializeAccounts)) !void {
    const args = ctx.args(InitializeArgs);
    
    // Accounts created by processInit, discriminators already written
    const tree = ctx.accounts().tree_account.getMut();
    const config = ctx.accounts().global_config.getMut();

    const authority_key = ctx.accounts().authority.id().*;
    tree.authority = authority_key;
    config.authority = authority_key;
    config.fee_recipient = args.fee_recipient;

    tree.next_index = 0;
    tree.root_index = 0;
    tree.max_deposit_amount = args.max_deposit_amount;
    tree.height = MERKLE_TREE_HEIGHT;
    tree.root_history_size = ROOT_HISTORY_SIZE;

    var level: u8 = 0;
    while (level < MERKLE_TREE_HEIGHT) : (level += 1) {
        tree.filled_subtrees[level] = ZERO_HASHES[level];
    }
    tree.root_history[0] = ZERO_HASHES[MERKLE_TREE_HEIGHT];

    config.deposit_fee_rate = 0;
    config.withdrawal_fee_rate = 25; // 0.25%
    config.fee_error_margin = 500;

    sol.log.log("Pool initialized");
}

fn updateConfigHandler(ctx: zero.Ctx(UpdateConfigAccounts)) !void {
    const args = ctx.args(UpdateConfigArgs);
    const config = ctx.accounts().global_config.getMut();
    const authority_key = ctx.accounts().authority.id().*;

    var matches = true;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (config.authority.bytes[i] != authority_key.bytes[i]) {
            matches = false;
            break;
        }
    }
    if (!matches) return error.Unauthorized;

    config.deposit_fee_rate = args.deposit_fee_rate;
    config.withdrawal_fee_rate = args.withdrawal_fee_rate;
    config.fee_error_margin = args.fee_error_margin;
    config.fee_recipient = args.fee_recipient;

    sol.log.log("Config updated");
    
    
}

fn initializeSplHandler(ctx: zero.Ctx(InitializeSplAccounts)) !void {
    const args = ctx.args(InitializeSplArgs);
    const tree = ctx.accounts().tree_account.getMut();
    const pool = ctx.accounts().token_pool.getMut();

    const authority_key = ctx.accounts().authority.id().*;
    tree.authority = authority_key;
    pool.authority = authority_key;

    tree.next_index = 0;
    tree.root_index = 0;
    tree.max_deposit_amount = args.max_deposit_amount;
    tree.height = MERKLE_TREE_HEIGHT;
    tree.root_history_size = ROOT_HISTORY_SIZE;

    var level: u8 = 0;
    while (level < MERKLE_TREE_HEIGHT) : (level += 1) {
        tree.filled_subtrees[level] = ZERO_HASHES[level];
    }
    tree.root_history[0] = ZERO_HASHES[MERKLE_TREE_HEIGHT];

    sol.log.log("SPL pool initialized");
}

fn transactHandler(ctx: zero.Ctx(TransactAccounts)) !void {
    const args = ctx.args(TransactArgs);
    const tree = ctx.accounts().tree_account.getMut();
    const config = ctx.accounts().global_config.get();
    const signer_info = ctx.accounts().signer.info();
    const null1_info = ctx.accounts().nullifier1.info();
    const null2_info = ctx.accounts().nullifier2.info();

    // Create nullifier accounts via CPI if they don't exist
    // If account already exists (has lamports), it means nullifier was already used
    if (ctx.accounts().nullifier1.lamports().* > 0) return error.NullifierAlreadyUsed;
    if (ctx.accounts().nullifier2.lamports().* > 0) return error.NullifierAlreadyUsed;

    // Derive PDA bumps and create nullifier accounts
    const null1_pda = sol.public_key.findProgramAddress(.{ "nullifier", &args.input_nullifier1 }, ctx.programId().*) catch return error.InvalidNullifierPDA;
    const null2_pda = sol.public_key.findProgramAddress(.{ "nullifier", &args.input_nullifier2 }, ctx.programId().*) catch return error.InvalidNullifierPDA;

    // Create nullifier 1 PDA
    const rent = sol.rent.Rent.getOrDefault();
    const null_space: u64 = 8 + 8; // discriminator + is_used
    const null_lamports = rent.getMinimumBalance(null_space);
    
    const null1_signer_seeds: [3][]const u8 = .{ "nullifier", &args.input_nullifier1, &null1_pda.bump_seed };
    sol.system_program.createAccountCpi(.{
        .from = signer_info,
        .to = null1_info,
        .lamports = null_lamports,
        .space = null_space,
        .owner = ctx.programId().*,
        .seeds = &.{&null1_signer_seeds},
    }) catch return error.CreateNullifierFailed;

    // Create nullifier 2 PDA
    const null2_signer_seeds: [3][]const u8 = .{ "nullifier", &args.input_nullifier2, &null2_pda.bump_seed };
    sol.system_program.createAccountCpi(.{
        .from = signer_info,
        .to = null2_info,
        .lamports = null_lamports,
        .space = null_space,
        .owner = ctx.programId().*,
        .seeds = &.{&null2_signer_seeds},
    }) catch return error.CreateNullifierFailed;

    sol.log.log("Nullifiers created");

    // Check root is known
    sol.log.log("Checking root...");
    if (!tree.isKnownRoot(args.root)) {
        sol.log.log("Unknown root!");
        return error.UnknownRoot;
    }
    sol.log.log("Root valid, verifying proof...");

    // Prepare public inputs for Groth16 verification
    // Order must match circom circuit: root, publicAmount, extDataHash, inputNullifier[2], outputCommitment[2]
    const public_amount_field = i64ToFieldElement(args.public_amount);
    const public_inputs: [NR_PUBLIC_INPUTS][32]u8 = .{
        args.root,
        public_amount_field,
        args.ext_data_hash,
        args.input_nullifier1,
        args.input_nullifier2,
        args.output_commitment1,
        args.output_commitment2,
    };

    // Verify Groth16 proof
    const is_valid = try verifyGroth16Proof(args.proof, public_inputs);
    if (!is_valid) return error.InvalidProof;

    sol.log.log("Proof verified");

    // Handle SOL transfer based on public_amount
    if (args.public_amount > 0) {
        // Deposit: user -> pool_vault via System Program CPI
        const deposit_amount: u64 = @intCast(args.public_amount);
        
        // Check deposit limit
        if (deposit_amount > tree.max_deposit_amount) {
            return error.DepositLimitExceeded;
        }
        
        // Calculate deposit fee
        const fee = (deposit_amount * config.deposit_fee_rate) / FEE_DENOMINATOR;
        const net_amount = deposit_amount - fee;
        
        // Transfer net amount to pool via CPI
        sol.system_program.transferCpi(.{
            .from = signer_info,
            .to = ctx.accounts().pool_vault.info(),
            .lamports = net_amount,
        }) catch return error.TransferFailed;
        
        // Transfer fee to fee recipient via CPI
        if (fee > 0) {
            sol.system_program.transferCpi(.{
                .from = signer_info,
                .to = ctx.accounts().fee_recipient.info(),
                .lamports = fee,
            }) catch return error.TransferFailed;
        }
        
        sol.log.log("Deposit completed");
        
    } else if (args.public_amount < 0) {
        // Withdrawal: pool_vault -> user via CPI with signer seeds
        const withdraw_amount: u64 = @intCast(-args.public_amount);
        
        // Calculate withdrawal fee
        const fee = (withdraw_amount * config.withdrawal_fee_rate) / FEE_DENOMINATOR;
        const net_amount = withdraw_amount - fee;
        
        const pool_vault_info = ctx.accounts().pool_vault.info();
        const recipient_info = ctx.accounts().recipient.info();
        
        // Derive the bump by trying to match the pool_vault address
        var bump: u8 = 255;
        while (bump > 0) : (bump -= 1) {
            const bump_slice = [_]u8{bump};
            const seeds_with_bump = [_][]const u8{
                "pool_vault",
                &bump_slice,
            };
            const derived = sol.PublicKey.createProgramAddress(&seeds_with_bump, ctx.programId().*) catch continue;
            if (std.mem.eql(u8, &derived.bytes, &pool_vault_info.id.bytes)) {
                break;
            }
        }
        
        // Transfer net amount to RECIPIENT (not signer!) via CPI with signer seeds
        const bump_slice = [_]u8{bump};
        const transfer_seeds = [_][]const u8{
            "pool_vault",
            &bump_slice,
        };
        const signer_seeds = [_][]const []const u8{&transfer_seeds};
        
        sol.system_program.transferCpi(.{
            .from = pool_vault_info,
            .to = recipient_info,  // Transfer to recipient, not signer!
            .lamports = net_amount,
            .seeds = &signer_seeds,
        }) catch return error.TransferFailed;
        
        // Transfer fee to fee recipient if any
        if (fee > 0) {
            sol.system_program.transferCpi(.{
                .from = pool_vault_info,
                .to = ctx.accounts().fee_recipient.info(),
                .lamports = fee,
                .seeds = &signer_seeds,
            }) catch return error.TransferFailed;
        }
        
        sol.log.log("Withdrawal completed");
        
    }

    // Nullifiers are marked as used by virtue of their PDA accounts being created
    // If account exists, nullifier was already used (checked at start of function)

    // Get next index before insert
    const next_index = tree.next_index;
    
    sol.log.log("Inserting commitments...");

    // Insert output commitments
    _ = try insertLeaf(tree, args.output_commitment1);
    sol.log.log("First commitment inserted");
    _ = try insertLeaf(tree, args.output_commitment2);
    sol.log.log("Second commitment inserted");

    // Emit commitment events
    emitCommitmentEvent(next_index, args.output_commitment1);
    emitCommitmentEvent(next_index + 1, args.output_commitment2);

    sol.log.log("Transact completed");
}

fn transactSplHandler(ctx: zero.Ctx(TransactSplAccounts)) !void {
    const args = ctx.args(TransactArgs);
    const tree = ctx.accounts().tree_account.getMut();
    const config = ctx.accounts().global_config.get();
    const user_info = ctx.accounts().user.info();
    const null1_info = ctx.accounts().nullifier1.info();
    const null2_info = ctx.accounts().nullifier2.info();

    // Create nullifier accounts via CPI if they don't exist
    if (ctx.accounts().nullifier1.lamports().* > 0) return error.NullifierAlreadyUsed;
    if (ctx.accounts().nullifier2.lamports().* > 0) return error.NullifierAlreadyUsed;

    // Derive PDA bumps and create nullifier accounts
    const null1_pda_spl = sol.public_key.findProgramAddress(.{ "nullifier", &args.input_nullifier1 }, ctx.programId().*) catch return error.InvalidNullifierPDA;
    const null2_pda_spl = sol.public_key.findProgramAddress(.{ "nullifier", &args.input_nullifier2 }, ctx.programId().*) catch return error.InvalidNullifierPDA;

    const rent = sol.rent.Rent.getOrDefault();
    const null_space: u64 = 8 + 8;
    const null_lamports = rent.getMinimumBalance(null_space);
    
    const null1_signer_seeds_spl: [3][]const u8 = .{ "nullifier", &args.input_nullifier1, &null1_pda_spl.bump_seed };
    sol.system_program.createAccountCpi(.{
        .from = user_info,
        .to = null1_info,
        .lamports = null_lamports,
        .space = null_space,
        .owner = ctx.programId().*,
        .seeds = &.{&null1_signer_seeds_spl},
    }) catch return error.CreateNullifierFailed;

    const null2_signer_seeds_spl: [3][]const u8 = .{ "nullifier", &args.input_nullifier2, &null2_pda_spl.bump_seed };
    sol.system_program.createAccountCpi(.{
        .from = user_info,
        .to = null2_info,
        .lamports = null_lamports,
        .space = null_space,
        .owner = ctx.programId().*,
        .seeds = &.{&null2_signer_seeds_spl},
    }) catch return error.CreateNullifierFailed;

    // Check root is known
    if (!tree.isKnownRoot(args.root)) return error.UnknownRoot;

    // Prepare public inputs for Groth16 verification
    // Order must match circom circuit: root, publicAmount, extDataHash, inputNullifier[2], outputCommitment[2]
    const public_amount_field = i64ToFieldElement(args.public_amount);
    const public_inputs: [NR_PUBLIC_INPUTS][32]u8 = .{
        args.root,
        public_amount_field,
        args.ext_data_hash,
        args.input_nullifier1,
        args.input_nullifier2,
        args.output_commitment1,
        args.output_commitment2,
    };

    // Verify Groth16 proof
    const is_valid = try verifyGroth16Proof(args.proof, public_inputs);
    if (!is_valid) return error.InvalidProof;

    sol.log.log("Proof verified");

    // Handle SPL Token transfer via CPI
    if (args.public_amount > 0) {
        // Deposit: user_token_account -> vault_token_account
        const deposit_amount: u64 = @intCast(args.public_amount);
        
        // Check deposit limit
        if (deposit_amount > tree.max_deposit_amount) {
            return error.DepositLimitExceeded;
        }
        
        // Calculate deposit fee
        const fee = (deposit_amount * config.deposit_fee_rate) / FEE_DENOMINATOR;
        const net_amount = deposit_amount - fee;
        
        // Transfer net amount to vault
        try transferTokensCpi(
            ctx.accounts().user_token_account.info(),
            ctx.accounts().vault_token_account.info(),
            ctx.accounts().user.info(),
            net_amount,
        );
        
        // Transfer fee to fee recipient
        if (fee > 0) {
            try transferTokensCpi(
                ctx.accounts().user_token_account.info(),
                ctx.accounts().fee_recipient_ata.info(),
                ctx.accounts().user.info(),
                fee,
            );
            
        }
        
        sol.log.log("Token deposit completed");
        
    } else if (args.public_amount < 0) {
        // Withdrawal: vault_token_account -> user_token_account
        const withdraw_amount: u64 = @intCast(-args.public_amount);
        
        // Calculate withdrawal fee
        const fee = (withdraw_amount * config.withdrawal_fee_rate) / FEE_DENOMINATOR;
        const net_amount = withdraw_amount - fee;
        
        // PDA seeds for vault authority
        const tree_key = ctx.accounts().tree_account.id();
        const seeds: [2][]const u8 = .{
            "vault_authority",
            &tree_key.bytes,
        };
        
        // Transfer net amount to user
        try transferTokensFromPdaCpi(
            ctx.accounts().vault_token_account.info(),
            ctx.accounts().user_token_account.info(),
            ctx.accounts().vault_authority.info(),
            net_amount,
            &seeds,
        );
        
        // Transfer fee to fee recipient
        if (fee > 0) {
            try transferTokensFromPdaCpi(
                ctx.accounts().vault_token_account.info(),
                ctx.accounts().fee_recipient_ata.info(),
                ctx.accounts().vault_authority.info(),
                fee,
                &seeds,
            );
            
        }
        
        sol.log.log("Token withdrawal completed");
        
    }

    // Nullifiers marked as used by PDA creation above

    // Get next index before insert
    const next_index = tree.next_index;

    // Insert output commitments
    _ = try insertLeaf(tree, args.output_commitment1);
    _ = try insertLeaf(tree, args.output_commitment2);

    // Emit commitment events
    emitCommitmentEvent(next_index, args.output_commitment1);
    emitCommitmentEvent(next_index + 1, args.output_commitment2);

    sol.log.log("Transact SPL completed");
}

// ============================================================================
// Program Definition (for IDL generation)
// ============================================================================

pub const Program = struct {
    pub const id = PROGRAM_ID;
    pub const name = "privacy_pool";
    pub const version = "0.1.0";
    pub const spec = "0.1.0";

    /// Instruction definitions for IDL
    pub const instructions = .{
        idl.InstructionWithDocs(
            "initialize",
            InitializeAccounts,
            InitializeArgs,
            "Initialize a new SOL privacy pool with Merkle tree",
        ),
        idl.InstructionWithDocs(
            "update_config",
            UpdateConfigAccounts,
            UpdateConfigArgs,
            "Update global configuration (fees, limits)",
        ),
        idl.InstructionWithDocs(
            "initialize_spl",
            InitializeSplAccounts,
            InitializeSplArgs,
            "Initialize a new SPL Token privacy pool",
        ),
        idl.InstructionWithDocs(
            "transact",
            TransactAccounts,
            TransactArgs,
            "Execute a SOL transaction with ZK proof (deposit/withdraw/transfer)",
        ),
        idl.InstructionWithDocs(
            "transact_spl",
            TransactSplAccounts,
            TransactArgs,
            "Execute an SPL Token transaction with ZK proof",
        ),
    };

    /// Account definitions for IDL
    pub const accounts = .{
        idl.AccountDefWithDocs("TreeAccount", TreeAccount, "Merkle tree account storing commitments"),
        idl.AccountDefWithDocs("GlobalConfig", GlobalConfig, "Global configuration for fees"),
        idl.AccountDefWithDocs("NullifierAccount", NullifierAccount, "Nullifier to prevent double-spending"),
        idl.AccountDefWithDocs("TokenPoolAccount", TokenPoolAccount, "SPL Token pool configuration"),
    };

    /// Custom errors
    pub const errors = enum(u32) {
        InvalidProof = 6000,
        InvalidRoot = 6001,
        NullifierAlreadyUsed = 6002,
        TreeFull = 6003,
        DepositLimitExceeded = 6004,
        InsufficientFunds = 6005,
        Unauthorized = 6006,
    };

    /// Events
    pub const events = .{
        idl.EventDef("CommitmentData", struct {
            index: u64,
            commitment: [32]u8,
        }),
    };

    /// Constants
    pub const constants = .{
        idl.ConstantDef("MERKLE_TREE_HEIGHT", u8, MERKLE_TREE_HEIGHT),
        idl.ConstantDef("ROOT_HISTORY_SIZE", u64, ROOT_HISTORY_SIZE),
        idl.ConstantDef("PROOF_SIZE", u64, PROOF_SIZE),
        idl.ConstantDef("NR_PUBLIC_INPUTS", u64, NR_PUBLIC_INPUTS),
        idl.ConstantDef("FEE_DENOMINATOR", u64, FEE_DENOMINATOR),
    };
};

// ============================================================================
// Program Entry
// ============================================================================

comptime {
    @setEvalBranchQuota(100000);
    zero.program(.{
        zero.ix("initialize", InitializeAccounts, initializeHandler),
        zero.ix("update_config", UpdateConfigAccounts, updateConfigHandler),
        zero.ix("initialize_spl", InitializeSplAccounts, initializeSplHandler),
        zero.ix("transact", TransactAccounts, transactHandler),
        zero.ix("transact_spl", TransactSplAccounts, transactSplHandler),
    });
}
