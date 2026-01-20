use solana_sdk::pubkey::Pubkey;
use std::str::FromStr;

/// Program ID for privacy-zig on testnet
pub const PROGRAM_ID: &str = "Dz82AAVPumnUys5SQ8HMat5iD6xiBVMGC2xJiJdZkpbT";

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
            tree_account: Pubkey::from_str("2h8oJdtfe9AE8r3Dmp49iBruUMfQQMmo6r63q79vxUN1").unwrap(),
            global_config: Pubkey::from_str("9qQELDcp6Z48tLpsDs6RtSQbYx5GpquxB4staTKQz15i").unwrap(),
            pool_vault: Pubkey::from_str("Cd6ntF7dtCqWiEnitLyukEVKN7VaCVkF1ta9VryP2zYq").unwrap(),
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
