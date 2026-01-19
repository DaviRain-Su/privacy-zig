//! Test with poseidon using extern fn

const sol = @import("solana_program_sdk");
const anchor = @import("sol_anchor_zig");
const zero = anchor.zero_cu;
const bpf = sol.bpf;

const TestAccounts = struct {
    account: zero.Mut(0),
};

const TestArgs = extern struct {
    input: [32]u8,
};

/// Poseidon hash using extern fn (correct for BPF)
fn poseidonHash(input: [32]u8) [32]u8 {
    var data: [64]u8 = undefined;
    @memcpy(data[0..32], &input);
    @memcpy(data[32..64], &input);

    var result: [32]u8 = undefined;

    if (bpf.is_bpf_program) {
        const Syscall = struct {
            extern fn sol_poseidon(
                params: u64,
                endianness: u64,
                vals: [*]const u8,
                vals_len: u64,
                result: [*]u8,
            ) callconv(.c) u64;
        };
        _ = Syscall.sol_poseidon(0, 0, &data, 64, &result);
    }

    return result;
}

fn testHandler(ctx: zero.Ctx(TestAccounts)) !void {
    const args = ctx.args(TestArgs);
    const hash = poseidonHash(args.input);
    _ = hash;
    sol.log.log("Hash computed");
}

comptime {
    zero.program(.{
        zero.ix("test", TestAccounts, testHandler),
    });
}
