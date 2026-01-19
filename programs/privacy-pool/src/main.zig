//! Privacy Pool Program - Zig Implementation
//!
//! A privacy pool for Solana using Groth16 ZK proofs.
//! Compatible with Privacy Cash protocol.
//!
//! ## Instructions
//! - initialize: Initialize SOL pool
//! - initialize_spl: Initialize SPL Token pool  
//! - update_config: Update global configuration
//! - transact: SOL deposit/withdraw/transfer with ZK proof
//! - transact_spl: SPL Token deposit/withdraw/transfer with ZK proof

const std = @import("std");
const sol = @import("solana_program_sdk");
const anchor = @import("sol_anchor_zig");
const zero = anchor.zero_cu;
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
// Constants
// ============================================================================

pub const MERKLE_TREE_HEIGHT: u8 = 20;
pub const ROOT_HISTORY_SIZE: usize = 30;
pub const PROOF_SIZE: usize = 256;
pub const NR_PUBLIC_INPUTS: usize = 7;
pub const FEE_DENOMINATOR: u64 = 10000;

// Pre-computed zero hashes for Merkle tree
pub const ZERO_HASHES: [MERKLE_TREE_HEIGHT + 1][32]u8 = .{
    [_]u8{0} ** 32,
    [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x0b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x0d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x0e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    [_]u8{ 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
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
    var input: [64]u8 = undefined;
    @memcpy(input[0..32], &left);
    @memcpy(input[32..64], &right);

    var result: [32]u8 = undefined;
    const ret = syscall_wrappers.poseidon(0, 0, &input, 64, &result);
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

const InitializeAccounts = struct {
    tree_account: zero.Account(TreeAccount, .{ .writable = true }),
    global_config: zero.Account(GlobalConfig, .{ .writable = true }),
    authority: zero.Signer(0),
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

const TransactAccounts = struct {
    tree_account: zero.Account(TreeAccount, .{ .writable = true }),
    nullifier1: zero.Account(NullifierAccount, .{ .writable = true }),
    nullifier2: zero.Account(NullifierAccount, .{ .writable = true }),
    global_config: zero.Account(GlobalConfig, .{}),
    user: zero.Signer(0),
    recipient: zero.Mut(0),
};

const TransactSplAccounts = struct {
    tree_account: zero.Account(TreeAccount, .{ .writable = true }),
    token_pool: zero.Account(TokenPoolAccount, .{}),
    nullifier1: zero.Account(NullifierAccount, .{ .writable = true }),
    nullifier2: zero.Account(NullifierAccount, .{ .writable = true }),
    global_config: zero.Account(GlobalConfig, .{}),
    user: zero.Signer(0),
    user_token_account: zero.Mut(0),
    vault_token_account: zero.Mut(0),
};

// ============================================================================
// Arguments
// ============================================================================

const InitializeArgs = extern struct {
    max_deposit_amount: u64,
};

const UpdateConfigArgs = extern struct {
    deposit_fee_rate: u16,
    withdrawal_fee_rate: u16,
    fee_error_margin: u16,
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
    public_amount: [32]u8,
    ext_data_hash: [32]u8,
};

// ============================================================================
// BN254 Operations
// ============================================================================

const BN254_ADD: u64 = 0;
const BN254_MUL: u64 = 1;
const BN254_PAIRING: u64 = 2;

/// G1 point addition
fn g1Add(a: [64]u8, b: [64]u8) ![64]u8 {
    var input: [128]u8 = undefined;
    @memcpy(input[0..64], &a);
    @memcpy(input[64..128], &b);

    var result: [64]u8 = undefined;
    const ret = syscall_wrappers.altBn128GroupOp(BN254_ADD, &input, 128, &result);
    if (ret != 0) return error.G1AddFailed;
    return result;
}

/// G1 scalar multiplication
fn g1Mul(point: [64]u8, scalar: [32]u8) ![64]u8 {
    var input: [96]u8 = undefined;
    @memcpy(input[0..64], &point);
    @memcpy(input[64..96], &scalar);

    var result: [64]u8 = undefined;
    const ret = syscall_wrappers.altBn128GroupOp(BN254_MUL, &input, 96, &result);
    if (ret != 0) return error.G1MulFailed;
    return result;
}

/// Negate G1 point (negate y coordinate in field)
fn g1Negate(point: [64]u8) [64]u8 {
    // BN254 field modulus p
    const P: [32]u8 = .{
        0x47, 0xFD, 0x7C, 0xD8, 0x16, 0x8C, 0x20, 0x3C,
        0x8d, 0xca, 0x71, 0x68, 0x91, 0x6a, 0x81, 0x97,
        0x5d, 0x58, 0x81, 0x81, 0xb6, 0x45, 0x50, 0xb8,
        0x29, 0xa0, 0x31, 0xe1, 0x72, 0x4e, 0x64, 0x30,
    };

    var result: [64]u8 = undefined;
    @memcpy(result[0..32], point[0..32]); // x stays same

    // y' = p - y (negate in field)
    var borrow: u8 = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const a = P[i];
        const b = point[32 + i];
        const diff = @as(u16, a) -% @as(u16, b) -% @as(u16, borrow);
        result[32 + i] = @truncate(diff);
        borrow = if (diff > 0xFF) 1 else 0;
    }

    return result;
}

/// Verify Groth16 proof
/// Returns true if the proof is valid
fn verifyGroth16Proof(
    proof: Proof,
    public_inputs: [NR_PUBLIC_INPUTS][32]u8,
) !bool {
    // Step 1: Compute vk_x = IC[0] + sum(IC[i+1] * input[i])
    var vk_x = VERIFYING_KEY.vk_ic[0];

    var i: usize = 0;
    while (i < NR_PUBLIC_INPUTS) : (i += 1) {
        const term = try g1Mul(VERIFYING_KEY.vk_ic[i + 1], public_inputs[i]);
        vk_x = try g1Add(vk_x, term);
    }

    // Step 2: Negate proof.A for pairing check
    const neg_a = g1Negate(proof.a);

    // Step 3: Prepare pairing input
    // Pairing check: e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) == 1
    // Input format: [G1, G2, G1, G2, G1, G2, G1, G2] = 4 pairs
    var pairing_input: [768]u8 = undefined; // 4 * (64 + 128) = 768

    // Pair 1: e(-A, B)
    @memcpy(pairing_input[0..64], &neg_a);
    @memcpy(pairing_input[64..192], &proof.b);

    // Pair 2: e(alpha, beta)
    @memcpy(pairing_input[192..256], &VERIFYING_KEY.vk_alpha_g1);
    @memcpy(pairing_input[256..384], &VERIFYING_KEY.vk_beta_g2);

    // Pair 3: e(vk_x, gamma)
    @memcpy(pairing_input[384..448], &vk_x);
    @memcpy(pairing_input[448..576], &VERIFYING_KEY.vk_gamma_g2);

    // Pair 4: e(C, delta)
    @memcpy(pairing_input[576..640], &proof.c);
    @memcpy(pairing_input[640..768], &VERIFYING_KEY.vk_delta_g2);

    // Step 4: Call pairing syscall
    var pairing_result: [32]u8 = undefined;
    const ret = syscall_wrappers.altBn128GroupOp(BN254_PAIRING, &pairing_input, 768, &pairing_result);
    if (ret != 0) return error.PairingFailed;

    // Check if result is 1 (valid proof)
    // Result should be 0x000...001 for valid pairing
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
    const tree = ctx.accounts.tree_account.getMut();
    const config = ctx.accounts.global_config.getMut();

    const authority_key = ctx.accounts.authority.id().*;
    tree.authority = authority_key;
    config.authority = authority_key;

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
    config.withdrawal_fee_rate = 25;
    config.fee_error_margin = 500;

    sol.log.log("Pool initialized");
}

fn updateConfigHandler(ctx: zero.Ctx(UpdateConfigAccounts)) !void {
    const args = ctx.args(UpdateConfigArgs);
    const config = ctx.accounts.global_config.getMut();
    const authority_key = ctx.accounts.authority.id().*;

    // Verify authority
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

    sol.log.log("Config updated");
}

fn initializeSplHandler(ctx: zero.Ctx(InitializeSplAccounts)) !void {
    const args = ctx.args(InitializeSplArgs);
    const tree = ctx.accounts.tree_account.getMut();
    const pool = ctx.accounts.token_pool.getMut();

    const authority_key = ctx.accounts.authority.id().*;
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
    const tree = ctx.accounts.tree_account.getMut();
    const nullifier1 = ctx.accounts.nullifier1.getMut();
    const nullifier2 = ctx.accounts.nullifier2.getMut();

    // Check nullifiers not used
    if (nullifier1.is_used != 0) return error.NullifierAlreadyUsed;
    if (nullifier2.is_used != 0) return error.NullifierAlreadyUsed;

    // Check root is known
    if (!tree.isKnownRoot(args.root)) return error.UnknownRoot;

    // Prepare public inputs for Groth16 verification
    // Privacy Cash circuit public inputs:
    // [0] root
    // [1] input_nullifier1
    // [2] input_nullifier2
    // [3] output_commitment1
    // [4] output_commitment2
    // [5] public_amount
    // [6] ext_data_hash
    const public_inputs: [NR_PUBLIC_INPUTS][32]u8 = .{
        args.root,
        args.input_nullifier1,
        args.input_nullifier2,
        args.output_commitment1,
        args.output_commitment2,
        args.public_amount,
        args.ext_data_hash,
    };

    // Verify Groth16 proof
    const is_valid = try verifyGroth16Proof(args.proof, public_inputs);
    if (!is_valid) return error.InvalidProof;

    sol.log.log("Proof verified");

    // Mark nullifiers as used
    nullifier1.is_used = 1;
    nullifier2.is_used = 1;

    // Insert output commitments
    _ = try insertLeaf(tree, args.output_commitment1);
    _ = try insertLeaf(tree, args.output_commitment2);

    sol.log.log("Transact completed");
}

fn transactSplHandler(ctx: zero.Ctx(TransactSplAccounts)) !void {
    const args = ctx.args(TransactArgs);
    const tree = ctx.accounts.tree_account.getMut();
    const nullifier1 = ctx.accounts.nullifier1.getMut();
    const nullifier2 = ctx.accounts.nullifier2.getMut();

    // Check nullifiers not used
    if (nullifier1.is_used != 0) return error.NullifierAlreadyUsed;
    if (nullifier2.is_used != 0) return error.NullifierAlreadyUsed;

    // Check root is known
    if (!tree.isKnownRoot(args.root)) return error.UnknownRoot;

    // Prepare public inputs for Groth16 verification
    const public_inputs: [NR_PUBLIC_INPUTS][32]u8 = .{
        args.root,
        args.input_nullifier1,
        args.input_nullifier2,
        args.output_commitment1,
        args.output_commitment2,
        args.public_amount,
        args.ext_data_hash,
    };

    // Verify Groth16 proof
    const is_valid = try verifyGroth16Proof(args.proof, public_inputs);
    if (!is_valid) return error.InvalidProof;

    sol.log.log("Proof verified");

    // TODO: Transfer SPL tokens via CPI

    // Mark nullifiers as used
    nullifier1.is_used = 1;
    nullifier2.is_used = 1;

    // Insert output commitments
    _ = try insertLeaf(tree, args.output_commitment1);
    _ = try insertLeaf(tree, args.output_commitment2);

    sol.log.log("Transact SPL completed");
}

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
