use solana_sdk::pubkey::Pubkey;
use std::str::FromStr;

/// Program ID for privacy-zig v2 on testnet (with separate recipient account)
pub const PROGRAM_ID: &str = "9A6fck3xNW2C6vwwqM4i1f4GeYpieuB7XKpF1YFduT6h";

/// Pool configuration with all relevant addresses
pub struct PoolConfig {
    pub program_id: Pubkey,
    pub tree_account: Pubkey,
    pub global_config: Pubkey,
    pub pool_vault: Pubkey,
    pub fee_recipient: Pubkey,
}

impl Default for PoolConfig {
    fn default() -> Self {
        Self {
            program_id: Pubkey::from_str(PROGRAM_ID).unwrap(),
            tree_account: Pubkey::from_str("4EGnTF2XfKDTBAszzoqQLe4zbmiURkWtkYQGnj99GiJf").unwrap(),
            global_config: Pubkey::from_str("7RUeHfhA6L7BUrmt9ZK7SJ9rmTMkD8qjjJgHRrUEGMq9").unwrap(),
            pool_vault: Pubkey::from_str("7nAKNHQwTeaybrnX6y3c3fLDL3qzQ3A6FGwMwH1LPc8q").unwrap(),
            fee_recipient: Pubkey::from_str("FM7WTd5Hr7ppp6vu3M4uAspF4DoRjrYPPFvAmqB7H95D").unwrap(),
        }
    }
}

/// Merkle tree constants
pub const MERKLE_TREE_HEIGHT: usize = 26;

/// BN254 field size
pub const FIELD_SIZE: &str = "21888242871839275222246405745257275088548364400416034343698204186575808495617";

/// Transact instruction discriminator
pub const TRANSACT_DISCRIMINATOR: [u8; 8] = [217, 149, 130, 143, 221, 52, 252, 119];
