use solana_sdk::pubkey::Pubkey;
use std::str::FromStr;

/// Program ID for privacy-zig on testnet (with separate recipient account)
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
            program_id: load_pubkey("PRIVACY_POOL_PROGRAM_ID", PROGRAM_ID),
            tree_account: load_pubkey(
                "PRIVACY_POOL_TREE_ACCOUNT",
                "4EGnTF2XfKDTBAszzoqQLe4zbmiURkWtkYQGnj99GiJf",
            ),
            global_config: load_pubkey(
                "PRIVACY_POOL_GLOBAL_CONFIG",
                "7RUeHfhA6L7BUrmt9ZK7SJ9rmTMkD8qjjJgHRrUEGMq9",
            ),
            pool_vault: load_pubkey(
                "PRIVACY_POOL_POOL_VAULT",
                "7nAKNHQwTeaybrnX6y3c3fLDL3qzQ3A6FGwMwH1LPc8q",
            ),
            // Use relayer address as fee_recipient to avoid exposing user address
            fee_recipient: load_pubkey(
                "PRIVACY_POOL_FEE_RECIPIENT",
                "FcuLoWBhZ8bNQRsSgGhH5NCJJbqK5uhHMZR6V21kyTgS",
            ),
        }
    }
}

fn load_pubkey(env_key: &str, fallback: &str) -> Pubkey {
    std::env::var(env_key)
        .ok()
        .and_then(|value| Pubkey::from_str(&value).ok())
        .unwrap_or_else(|| Pubkey::from_str(fallback).expect("Invalid fallback pubkey"))
}

/// Merkle tree constants
pub const MERKLE_TREE_HEIGHT: usize = 26;

/// BN254 field size
pub const FIELD_SIZE: &str = "21888242871839275222246405745257275088548364400416034343698204186575808495617";

/// Transact instruction discriminator
pub const TRANSACT_DISCRIMINATOR: [u8; 8] = [217, 149, 130, 143, 221, 52, 252, 119];
