//! Cryptographic utilities for privacy pool
//!
//! Implements Poseidon hash and Merkle tree in pure Rust.
//! ZK proof generation delegates to the circuit artifacts via subprocess.

use anyhow::{anyhow, Result};
use light_poseidon::{Poseidon, PoseidonBytesHasher, PoseidonHasher};
use ark_bn254::Fr;
use ark_ff::{BigInteger, PrimeField};
use num_bigint::BigUint;
use serde::{Deserialize, Serialize};
use std::str::FromStr;

/// BN254 scalar field modulus
pub const FIELD_SIZE: &str = "21888242871839275222246405745257275088548364400416034343698204186575808495617";

/// BN254 base field modulus (for G1 point negation)
pub const BN254_FIELD_MODULUS: &str = "21888242871839275222246405745257275088696311157297823662689037894645226208583";

/// Merkle tree height
pub const MERKLE_TREE_HEIGHT: usize = 26;

/// Poseidon hasher wrapper
pub struct PoseidonHash {
    hasher: Poseidon<Fr>,
}

impl PoseidonHash {
    pub fn new() -> Self {
        Self {
            hasher: Poseidon::<Fr>::new_circom(2).expect("Failed to create Poseidon hasher"),
        }
    }

    /// Hash two field elements
    pub fn hash2(&mut self, a: &Fr, b: &Fr) -> Fr {
        self.hasher.hash(&[*a, *b]).expect("Poseidon hash failed")
    }

    /// Hash a single field element (with padding)
    pub fn hash1(&mut self, a: &Fr) -> Fr {
        let mut hasher1 = Poseidon::<Fr>::new_circom(1).expect("Failed to create Poseidon hasher");
        hasher1.hash(&[*a]).expect("Poseidon hash failed")
    }

    /// Hash multiple field elements
    pub fn hash_many(&mut self, inputs: &[Fr]) -> Fr {
        let mut hasher = Poseidon::<Fr>::new_circom(inputs.len()).expect("Failed to create Poseidon hasher");
        hasher.hash(inputs).expect("Poseidon hash failed")
    }
}

impl Default for PoseidonHash {
    fn default() -> Self {
        Self::new()
    }
}

/// Convert bigint string to Fr
pub fn str_to_fr(s: &str) -> Result<Fr> {
    let big = BigUint::from_str(s).map_err(|e| anyhow!("Invalid bigint: {}", e))?;
    let bytes = big.to_bytes_le();
    let mut arr = [0u8; 32];
    let len = bytes.len().min(32);
    arr[..len].copy_from_slice(&bytes[..len]);
    Ok(Fr::from_le_bytes_mod_order(&arr))
}

/// Convert Fr to bigint string
pub fn fr_to_str(f: &Fr) -> String {
    let bytes = f.into_bigint().to_bytes_le();
    let big = BigUint::from_bytes_le(&bytes);
    big.to_string()
}

/// Convert Fr to big-endian bytes (32 bytes)
pub fn fr_to_be_bytes(f: &Fr) -> [u8; 32] {
    let bytes = f.into_bigint().to_bytes_be();
    let mut arr = [0u8; 32];
    let start = 32 - bytes.len();
    arr[start..].copy_from_slice(&bytes);
    arr
}

/// Generate random field element (for blinding/keys)
pub fn random_fr() -> Fr {
    use rand::RngCore;
    let mut rng = rand::thread_rng();
    let mut bytes = [0u8; 31]; // 31 bytes to ensure < field modulus
    rng.fill_bytes(&mut bytes);
    Fr::from_le_bytes_mod_order(&bytes)
}

/// Merkle tree for privacy pool
pub struct MerkleTree {
    height: usize,
    zeros: Vec<Fr>,
    pub leaves: Vec<Fr>,
    layers: Vec<Vec<Fr>>,
    hasher: PoseidonHash,
}

impl MerkleTree {
    pub fn new(height: usize) -> Self {
        let mut hasher = PoseidonHash::new();
        let zeros = Self::compute_zero_hashes(height, &mut hasher);
        Self {
            height,
            zeros,
            leaves: Vec::new(),
            layers: Vec::new(),
            hasher,
        }
    }

    fn compute_zero_hashes(height: usize, hasher: &mut PoseidonHash) -> Vec<Fr> {
        let mut zeros = vec![Fr::from(0u64)];
        for i in 1..=height {
            let prev = zeros[i - 1];
            zeros.push(hasher.hash2(&prev, &prev));
        }
        zeros
    }

    pub fn insert(&mut self, leaf: Fr) {
        self.leaves.push(leaf);
        self.rebuild();
    }

    pub fn insert_many(&mut self, leaves: &[Fr]) {
        self.leaves.extend_from_slice(leaves);
        self.rebuild();
    }

    fn rebuild(&mut self) {
        self.layers = vec![self.leaves.clone()];

        for level in 0..self.height {
            let current = &self.layers[level];
            let mut next = Vec::new();

            let mut i = 0;
            while i < current.len() {
                let left = current[i];
                let right = if i + 1 < current.len() {
                    current[i + 1]
                } else {
                    self.zeros[level]
                };
                next.push(self.hasher.hash2(&left, &right));
                i += 2;
            }

            if next.is_empty() {
                next.push(self.zeros[level + 1]);
            }

            self.layers.push(next);
        }
    }

    pub fn root(&self) -> Fr {
        if self.layers.is_empty() {
            return self.zeros[self.height];
        }
        self.layers[self.height][0]
    }

    pub fn get_path(&self, leaf_index: usize) -> (Vec<Fr>, Vec<u8>) {
        let mut path_elements = Vec::new();
        let mut path_indices = Vec::new();
        let mut current_index = leaf_index;

        for level in 0..self.height {
            let is_right = current_index % 2 == 1;
            let sibling_index = if is_right {
                current_index - 1
            } else {
                current_index + 1
            };

            path_indices.push(if is_right { 1u8 } else { 0u8 });

            let layer = &self.layers[level];
            if sibling_index < layer.len() {
                path_elements.push(layer[sibling_index]);
            } else {
                path_elements.push(self.zeros[level]);
            }

            current_index /= 2;
        }

        (path_elements, path_indices)
    }

    pub fn leaf_count(&self) -> usize {
        self.leaves.len()
    }
}

/// UTXO (Unspent Transaction Output) for privacy pool
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Utxo {
    /// Amount in lamports
    pub amount: u64,
    /// Owner's public key (Poseidon hash of private key)
    pub pubkey: String,
    /// Owner's private key
    pub privkey: String,
    /// Random blinding factor
    pub blinding: String,
    /// Commitment = Poseidon(amount, pubkey, blinding, mint)
    pub commitment: String,
}

impl Utxo {
    /// Generate a new UTXO with random keys
    pub fn new(amount: u64) -> Result<Self> {
        let mut hasher = PoseidonHash::new();
        
        let privkey = random_fr();
        let pubkey = hasher.hash1(&privkey);
        let blinding = random_fr();
        
        let mint = Fr::from(1u64); // SOL mint address
        let amount_fr = Fr::from(amount);
        
        let commitment = {
            let mut h = Poseidon::<Fr>::new_circom(4).expect("Failed to create Poseidon hasher");
            h.hash(&[amount_fr, pubkey, blinding, mint]).expect("Hash failed")
        };

        Ok(Self {
            amount,
            pubkey: fr_to_str(&pubkey),
            privkey: fr_to_str(&privkey),
            blinding: fr_to_str(&blinding),
            commitment: fr_to_str(&commitment),
        })
    }

    /// Create UTXO from existing values
    pub fn from_values(
        amount: u64,
        privkey: &str,
        pubkey: &str,
        blinding: &str,
    ) -> Result<Self> {
        let privkey_fr = str_to_fr(privkey)?;
        let pubkey_fr = str_to_fr(pubkey)?;
        let blinding_fr = str_to_fr(blinding)?;
        let mint = Fr::from(1u64);
        let amount_fr = Fr::from(amount);

        let commitment = {
            let mut h = Poseidon::<Fr>::new_circom(4).expect("Failed to create Poseidon hasher");
            h.hash(&[amount_fr, pubkey_fr, blinding_fr, mint]).expect("Hash failed")
        };

        Ok(Self {
            amount,
            pubkey: pubkey.to_string(),
            privkey: privkey.to_string(),
            blinding: blinding.to_string(),
            commitment: fr_to_str(&commitment),
        })
    }

    /// Compute nullifier for this UTXO at given leaf index
    pub fn compute_nullifier(&self, leaf_index: usize) -> Result<Fr> {
        let privkey = str_to_fr(&self.privkey)?;
        let commitment = str_to_fr(&self.commitment)?;
        let index_fr = Fr::from(leaf_index as u64);

        // signature = Poseidon(privkey, commitment, index)
        let signature = {
            let mut h = Poseidon::<Fr>::new_circom(3).expect("Failed to create Poseidon hasher");
            h.hash(&[privkey, commitment, index_fr]).expect("Hash failed")
        };

        // nullifier = Poseidon(commitment, index, signature)
        let nullifier = {
            let mut h = Poseidon::<Fr>::new_circom(3).expect("Failed to create Poseidon hasher");
            h.hash(&[commitment, index_fr, signature]).expect("Hash failed")
        };

        Ok(nullifier)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_poseidon_hash() {
        let mut hasher = PoseidonHash::new();
        let a = Fr::from(1u64);
        let b = Fr::from(2u64);
        let hash = hasher.hash2(&a, &b);
        assert_ne!(hash, Fr::from(0u64));
    }

    #[test]
    fn test_merkle_tree() {
        let mut tree = MerkleTree::new(4);
        assert_eq!(tree.leaf_count(), 0);

        let leaf1 = Fr::from(1u64);
        let leaf2 = Fr::from(2u64);

        tree.insert(leaf1);
        tree.insert(leaf2);

        assert_eq!(tree.leaf_count(), 2);

        let (path, indices) = tree.get_path(0);
        assert_eq!(path.len(), 4);
        assert_eq!(indices.len(), 4);
    }

    #[test]
    fn test_utxo() {
        let utxo = Utxo::new(1_000_000_000).unwrap();
        assert_eq!(utxo.amount, 1_000_000_000);
        assert!(!utxo.commitment.is_empty());

        let nullifier = utxo.compute_nullifier(0).unwrap();
        assert_ne!(nullifier, Fr::from(0u64));
    }
}
