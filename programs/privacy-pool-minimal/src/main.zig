//! Privacy Pool Minimal - Simple deposit/commitment tracking
//!
//! A simplified privacy pool for testing deployment.
//! Only tracks commitments - no Groth16 verification.

const anchor = @import("sol_anchor_zig");
const zero = anchor.zero_cu;
const sol = anchor.sdk;

// ============================================================================
// Program ID
// ============================================================================

pub const PROGRAM_ID = sol.PublicKey.comptimeFromBase58("PrivMin11111111111111111111111111111111111");

// ============================================================================
// Constants
// ============================================================================

const ROOT_HISTORY_SIZE: usize = 30;

// ============================================================================
// Account Structures
// ============================================================================

/// Pool state account
pub const PoolState = extern struct {
    /// Authority
    authority: sol.PublicKey,
    /// Next leaf index
    next_index: u64,
    /// Current root (simplified)
    current_root: [32]u8,
    /// Pool balance (lamports)
    balance: u64,
    /// Bump seed
    bump: u8,
    /// Padding
    _padding: [7]u8,
    /// Recent commitments (simple ring buffer)
    commitments: [ROOT_HISTORY_SIZE][32]u8,
};

// ============================================================================
// Accounts Definitions
// ============================================================================

const InitializeAccounts = struct {
    /// Pool state account
    pool: zero.Account(PoolState, .{
        .writable = true,
    }),
    /// Authority (signer, no data)
    authority: zero.Signer(0),
};

const DepositAccounts = struct {
    /// Pool state account
    pool: zero.Account(PoolState, .{
        .writable = true,
    }),
    /// Depositor (signer, no data)
    depositor: zero.Signer(0),
};

// ============================================================================
// Arguments
// ============================================================================

const InitializeArgs = extern struct {
    // No args needed
};

const DepositArgs = extern struct {
    commitment: [32]u8,
    amount: u64,
};

// ============================================================================
// Handlers
// ============================================================================

fn initializeHandler(ctx: zero.Ctx(InitializeAccounts)) !void {
    const pool = ctx.accounts.pool.getMut();
    
    pool.authority = ctx.accounts.authority.id().*;
    pool.next_index = 0;
    pool.current_root = [_]u8{0} ** 32;
    pool.balance = 0;
    pool.bump = 0;
    pool._padding = [_]u8{0} ** 7;
    
    // Zero out commitments
    for (&pool.commitments) |*c| {
        c.* = [_]u8{0} ** 32;
    }
    
    sol.log.print("Pool initialized", .{});
}

fn depositHandler(ctx: zero.Ctx(DepositAccounts)) !void {
    const args = ctx.args(DepositArgs);
    const pool = ctx.accounts.pool.getMut();
    
    sol.log.print("Deposit amount: {}", .{args.amount});
    
    // Store commitment
    const idx = pool.next_index % ROOT_HISTORY_SIZE;
    pool.commitments[idx] = args.commitment;
    pool.next_index += 1;
    
    // Update balance
    pool.balance += args.amount;
    
    // Simple root update
    pool.current_root = simpleHash(args.commitment);
    
    sol.log.print("Deposit successful, index: {}", .{pool.next_index - 1});
}

/// Simple hash function (for testing)
fn simpleHash(input: [32]u8) [32]u8 {
    var result: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        result[i] = input[i] ^ input[(i + 7) % 32] +% @as(u8, @truncate(i));
    }
    return result;
}

// ============================================================================
// Program Entry
// ============================================================================

comptime {
    zero.program(.{
        zero.ix("initialize", InitializeAccounts, initializeHandler),
        zero.ix("deposit", DepositAccounts, depositHandler),
    });
}
