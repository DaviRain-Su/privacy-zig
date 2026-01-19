//! Privacy Cash Verification Key
//!
//! This contains the real verification key from Privacy Cash's trusted setup.
//! Source: https://github.com/Privacy-Cash/privacy-cash/blob/main/artifacts/circuits/verifyingkey2.json
//!
//! Circuit: transaction2.circom
//! Protocol: Groth16
//! Curve: BN254 (alt_bn128)
//! Public Inputs: 7

const std = @import("std");
const groth16 = @import("groth16.zig");

// ============================================================================
// Helper: Convert decimal string to big-endian bytes
// ============================================================================

fn decimalToBE32(comptime decimal: []const u8) [32]u8 {
    @setEvalBranchQuota(10000);
    var result: [32]u8 = [_]u8{0} ** 32;
    var value: u256 = 0;
    
    for (decimal) |c| {
        value = value * 10 + (c - '0');
    }
    
    // Convert to big-endian
    inline for (0..32) |i| {
        result[31 - i] = @truncate(value & 0xff);
        value >>= 8;
    }
    
    return result;
}

fn g1Point(comptime x: []const u8, comptime y: []const u8) [64]u8 {
    return decimalToBE32(x) ++ decimalToBE32(y);
}

fn g2Point(
    comptime x0: []const u8,
    comptime x1: []const u8,
    comptime y0: []const u8,
    comptime y1: []const u8,
) [128]u8 {
    // G2 point format: [x.c1, x.c0, y.c1, y.c0] (each 32 bytes, big-endian)
    // Note: snarkjs uses [c0, c1] order, Solana expects [c1, c0]
    return decimalToBE32(x1) ++ decimalToBE32(x0) ++ decimalToBE32(y1) ++ decimalToBE32(y0);
}

// ============================================================================
// Privacy Cash Verification Key Constants
// ============================================================================

/// Alpha G1 point
pub const ALPHA_G1: [64]u8 = g1Point(
    "20491192805390485299153009773594534940189261866228447918068658471970481763042",
    "9383485363053290200918347156157836566562967994039712273449902621266178545958",
);

/// Beta G2 point
pub const BETA_G2: [128]u8 = g2Point(
    "6375614351688725206403948262868962793625744043794305715222011528459656738731",
    "4252822878758300859123897981450591353533073413197771768651442665752259397132",
    "10505242626370262277552901082094356697409835680220590971873171140371331206856",
    "21847035105528745403288232691147584728191162732299865338377159692350059136679",
);

/// Gamma G2 point
pub const GAMMA_G2: [128]u8 = g2Point(
    "10857046999023057135944570762232829481370756359578518086990519993285655852781",
    "11559732032986387107991004021392285783925812861821192530917403151452391805634",
    "8495653923123431417604973247489272438418190587263600148770280649306958101930",
    "4082367875863433681332203403145435568316851327593401208105741076214120093531",
);

/// Delta G2 point
pub const DELTA_G2: [128]u8 = g2Point(
    "15604859252277219118509451837892348720850543020982519106278756751459800819512",
    "11754476599326556907401981901157282195683129005513679264912740536253364963164",
    "20563199534868918237684673006901857826940315752290163873288913320602259101523",
    "9767868217614493676656858512230921722923175186970489919264050761484831443032",
);

/// IC points (8 points for 7 public inputs)
pub const IC: [8][64]u8 = .{
    // IC[0]
    g1Point(
        "16044901306341784321705611029830270774453336627567197458088446391790199677130",
        "9990917124417351217379324238847035080441811894409789178316190179220389265793",
    ),
    // IC[1]
    g1Point(
        "6142001535317089426924543130017076907983762958151349567623362128962423953772",
        "20915781792434991000096750595279710736921794116860244848965403008252346015202",
    ),
    // IC[2]
    g1Point(
        "11946693785576523203302059724896672735526142350090941192926537950905333584704",
        "74711547027406712650374299903252469415093937986832589108208907466220538771",
    ),
    // IC[3]
    g1Point(
        "3154432174070549405279827769959558283943388840717748976927301469474515576507",
        "13217305452092387581635919711924462970260721306017210773997426633605520153677",
    ),
    // IC[4]
    g1Point(
        "15667808700462157537346618354299527664751409765578051832402171828334742190747",
        "21255036738913778878393514573634682013696354881823799704745122741721845907860",
    ),
    // IC[5]
    g1Point(
        "16601866542014645599279135707060238291574011458062844693520684560896082578851",
        "11144751985999046911110060325192950246838935332104002253678431913027469594004",
    ),
    // IC[6]
    g1Point(
        "5017933925133380992915916925528689424425603817119798276001672086894532503116",
        "5700954021929303460813754181925200157061362771890511970325325323619565098403",
    ),
    // IC[7]
    g1Point(
        "599891033659993930310226335285499973679513106682293449281172760701845688664",
        "18800530419668759025146111638308809520938869715566481754753044243225642837625",
    ),
};

/// Number of public inputs for transaction2 circuit
pub const NUM_PUBLIC_INPUTS: usize = 7;

// ============================================================================
// Verification Key Instance
// ============================================================================

/// Pre-constructed verification key for Privacy Cash
pub const VERIFICATION_KEY: groth16.VerificationKey = .{
    .alpha_g1 = ALPHA_G1,
    .beta_g2 = BETA_G2,
    .gamma_g2 = GAMMA_G2,
    .delta_g2 = DELTA_G2,
    .ic = &IC,
};

// ============================================================================
// Public Input Format
// ============================================================================

/// Public inputs for Privacy Cash transaction2 circuit
///
/// These are the values that are publicly visible on-chain.
pub const PublicInputs = struct {
    /// Merkle root of the commitment tree
    merkle_root: [32]u8,
    /// Nullifier 1 (prevents double-spending of input 1)
    nullifier1: [32]u8,
    /// Nullifier 2 (prevents double-spending of input 2)
    nullifier2: [32]u8,
    /// Output commitment 1
    commitment1: [32]u8,
    /// Output commitment 2
    commitment2: [32]u8,
    /// Public amount (positive = deposit, negative = withdrawal)
    public_amount: [32]u8,
    /// External data hash (recipient, relayer fee, etc.)
    ext_data_hash: [32]u8,

    /// Convert to array of scalars for verification
    pub fn toScalars(self: *const PublicInputs) [NUM_PUBLIC_INPUTS][32]u8 {
        return .{
            self.merkle_root,
            self.nullifier1,
            self.nullifier2,
            self.commitment1,
            self.commitment2,
            self.public_amount,
            self.ext_data_hash,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "privacy_cash_vk: constants are valid" {
    // Check sizes
    try std.testing.expectEqual(@as(usize, 64), ALPHA_G1.len);
    try std.testing.expectEqual(@as(usize, 128), BETA_G2.len);
    try std.testing.expectEqual(@as(usize, 128), GAMMA_G2.len);
    try std.testing.expectEqual(@as(usize, 128), DELTA_G2.len);
    try std.testing.expectEqual(@as(usize, 8), IC.len);

    // Check IC point sizes
    for (IC) |ic_point| {
        try std.testing.expectEqual(@as(usize, 64), ic_point.len);
    }
}

test "privacy_cash_vk: verification key structure" {
    try std.testing.expectEqual(@as(usize, NUM_PUBLIC_INPUTS), VERIFICATION_KEY.numPublicInputs());
}

test "privacy_cash_vk: decimal to BE conversion" {
    // Test with known value: 1
    const one = decimalToBE32("1");
    try std.testing.expectEqual(@as(u8, 0), one[0]);
    try std.testing.expectEqual(@as(u8, 1), one[31]);

    // Test with known value: 256
    const n256 = decimalToBE32("256");
    try std.testing.expectEqual(@as(u8, 1), n256[30]);
    try std.testing.expectEqual(@as(u8, 0), n256[31]);
}

test "privacy_cash_vk: public inputs conversion" {
    const inputs = PublicInputs{
        .merkle_root = [_]u8{1} ** 32,
        .nullifier1 = [_]u8{2} ** 32,
        .nullifier2 = [_]u8{3} ** 32,
        .commitment1 = [_]u8{4} ** 32,
        .commitment2 = [_]u8{5} ** 32,
        .public_amount = [_]u8{6} ** 32,
        .ext_data_hash = [_]u8{7} ** 32,
    };

    const scalars = inputs.toScalars();
    try std.testing.expectEqual(@as(usize, 7), scalars.len);
    try std.testing.expectEqualSlices(u8, &inputs.merkle_root, &scalars[0]);
    try std.testing.expectEqualSlices(u8, &inputs.ext_data_hash, &scalars[6]);
}
