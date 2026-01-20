//! ZK proof generation for privacy pool transactions
//!
//! Uses ark-circom to:
//! 1. Load circuit WASM for witness calculation
//! 2. Load zkey for proving key
//! 3. Generate Groth16 proofs using arkworks

use anyhow::{anyhow, Context, Result};
use ark_bn254::{Bn254, Fr, G1Affine, G2Affine};
use ark_circom::{read_zkey, CircomReduction, WitnessCalculator};
use ark_crypto_primitives::snark::SNARK;
use ark_ff::{BigInteger, PrimeField};
use ark_groth16::{Groth16, Proof, ProvingKey};
use ark_relations::r1cs::ConstraintMatrices;
use ark_std::rand::thread_rng;
use ark_std::UniformRand;
use num_bigint::BigInt;
use num_traits::ToPrimitive;
use std::collections::HashMap;
use std::fs::File;
use std::sync::Mutex;
use wasmer::Store;

use crate::crypto::{fr_to_be_bytes, MerkleTree, Utxo, MERKLE_TREE_HEIGHT, FIELD_SIZE};

/// BN254 base field modulus (for G1 point negation)
const BN254_FIELD_MODULUS: &str =
    "21888242871839275222246405745257275088696311157297823662689037894645226208583";

/// Prover for privacy pool transactions
pub struct PrivacyProver {
    params: ProvingKey<Bn254>,
    matrices: ConstraintMatrices<Fr>,
    wasm_path: String,
}

impl PrivacyProver {
    /// Load prover from circuit artifacts
    pub fn new(wasm_path: &str, zkey_path: &str) -> Result<Self> {
        // Load zkey
        let mut zkey_file = File::open(zkey_path)
            .with_context(|| format!("Failed to open zkey: {}", zkey_path))?;
        let (params, matrices) = read_zkey(&mut zkey_file)
            .map_err(|e| anyhow!("Failed to parse zkey: {:?}", e))?;

        Ok(Self {
            params,
            matrices,
            wasm_path: wasm_path.to_string(),
        })
    }

    /// Generate proof for a deposit transaction
    /// root should be the current on-chain Merkle tree root
    pub fn prove_deposit(
        &self,
        amount: u64,
        utxo: &Utxo,
        payer_pubkey_bytes: &[u8; 32],
        root: Fr,
    ) -> Result<TransactProofData> {

        // Compute dummy nullifiers for fresh deposit
        let dummy_utxo1 = Utxo::new(0)?;
        let dummy_utxo2 = Utxo::new(0)?;
        let nullifier1 = dummy_utxo1.compute_nullifier(0)?;
        let nullifier2 = dummy_utxo2.compute_nullifier(0)?;

        // Output UTXO
        let out_utxo1 = Utxo::from_values(amount, &utxo.privkey, &utxo.pubkey, &utxo.blinding)?;
        let out_utxo2 = Utxo::new(0)?;

        // ExtData hash
        let payer_num = BigInt::from_bytes_be(num_bigint::Sign::Plus, &payer_pubkey_bytes[0..8]);
        let ext_data_hash = self.compute_ext_data_hash(&payer_num, amount)?;

        // Build witness inputs
        let zero_path: Vec<BigInt> = (0..MERKLE_TREE_HEIGHT).map(|_| BigInt::from(0)).collect();
        
        let mut inputs: HashMap<String, Vec<BigInt>> = HashMap::new();
        inputs.insert("root".to_string(), vec![fr_to_bigint(&root)]);
        inputs.insert("publicAmount".to_string(), vec![BigInt::from(amount)]);
        inputs.insert("extDataHash".to_string(), vec![ext_data_hash]);
        inputs.insert("mintAddress".to_string(), vec![BigInt::from(1)]);
        inputs.insert("inputNullifier".to_string(), vec![
            fr_to_bigint(&nullifier1),
            fr_to_bigint(&nullifier2),
        ]);
        inputs.insert("inAmount".to_string(), vec![BigInt::from(0), BigInt::from(0)]);
        inputs.insert("inPrivateKey".to_string(), vec![
            str_to_bigint(&dummy_utxo1.privkey)?,
            str_to_bigint(&dummy_utxo2.privkey)?,
        ]);
        inputs.insert("inBlinding".to_string(), vec![
            str_to_bigint(&dummy_utxo1.blinding)?,
            str_to_bigint(&dummy_utxo2.blinding)?,
        ]);
        inputs.insert("inPathIndices".to_string(), vec![BigInt::from(0), BigInt::from(0)]);
        inputs.insert("inPathElements".to_string(), [zero_path.clone(), zero_path].concat());
        inputs.insert("outputCommitment".to_string(), vec![
            str_to_bigint(&out_utxo1.commitment)?,
            str_to_bigint(&out_utxo2.commitment)?,
        ]);
        inputs.insert("outAmount".to_string(), vec![BigInt::from(amount), BigInt::from(0)]);
        inputs.insert("outPubkey".to_string(), vec![
            str_to_bigint(&utxo.pubkey)?,
            str_to_bigint(&out_utxo2.pubkey)?,
        ]);
        inputs.insert("outBlinding".to_string(), vec![
            str_to_bigint(&utxo.blinding)?,
            str_to_bigint(&out_utxo2.blinding)?,
        ]);

        // Generate proof
        let (proof, public_signals) = self.generate_proof(inputs)?;
        self.format_proof(&proof, &public_signals)
    }

    /// Generate proof for a withdrawal transaction
    pub fn prove_withdraw(
        &self,
        utxo: &Utxo,
        leaf_index: usize,
        tree: &MerkleTree,
        recipient_pubkey_bytes: &[u8; 32],
    ) -> Result<TransactProofData> {
        use light_poseidon::{Poseidon, PoseidonHasher};
        use crate::crypto::{str_to_fr, random_fr, fr_to_str};
        
        let amount = utxo.amount;
        let root = tree.root();
        let (path_elements, _path_indices) = tree.get_path(leaf_index);

        // Get utxo owner's keys
        let privkey = str_to_fr(&utxo.privkey)?;
        let pubkey = str_to_fr(&utxo.pubkey)?;
        let mint = Fr::from(1u64); // SOL mint
        
        // Compute nullifier1 for real input
        let nullifier1 = utxo.compute_nullifier(leaf_index)?;
        
        // Dummy second input - uses SAME privkey/pubkey but different blinding
        let dummy_blinding = random_fr();
        let dummy_commitment = {
            let mut h = Poseidon::<Fr>::new_circom(4).map_err(|e| anyhow!("Poseidon init failed: {:?}", e))?;
            h.hash(&[Fr::from(0u64), pubkey, dummy_blinding, mint]).map_err(|e| anyhow!("Hash failed: {:?}", e))?
        };
        let dummy_sig = {
            let mut h = Poseidon::<Fr>::new_circom(3).map_err(|e| anyhow!("Poseidon init failed: {:?}", e))?;
            h.hash(&[privkey, dummy_commitment, Fr::from(0u64)]).map_err(|e| anyhow!("Hash failed: {:?}", e))?
        };
        let nullifier2 = {
            let mut h = Poseidon::<Fr>::new_circom(3).map_err(|e| anyhow!("Poseidon init failed: {:?}", e))?;
            h.hash(&[dummy_commitment, Fr::from(0u64), dummy_sig]).map_err(|e| anyhow!("Hash failed: {:?}", e))?
        };

        // Output commitments (both zero amount, same pubkey)
        let out_blinding1 = random_fr();
        let out_blinding2 = random_fr();
        let out_commitment1 = {
            let mut h = Poseidon::<Fr>::new_circom(4).map_err(|e| anyhow!("Poseidon init failed: {:?}", e))?;
            h.hash(&[Fr::from(0u64), pubkey, out_blinding1, mint]).map_err(|e| anyhow!("Hash failed: {:?}", e))?
        };
        let out_commitment2 = {
            let mut h = Poseidon::<Fr>::new_circom(4).map_err(|e| anyhow!("Poseidon init failed: {:?}", e))?;
            h.hash(&[Fr::from(0u64), pubkey, out_blinding2, mint]).map_err(|e| anyhow!("Hash failed: {:?}", e))?
        };

        // Public amount (negative for withdrawal, represented in field)
        let field_size = num_bigint::BigUint::parse_bytes(
            b"21888242871839275222246405745257275088548364400416034343698204186575808495617",
            10,
        ).unwrap();
        let neg_amount = &field_size - num_bigint::BigUint::from(amount);
        let public_amount_bigint = BigInt::from_biguint(num_bigint::Sign::Plus, neg_amount);

        // ExtData hash
        let recipient_num = BigInt::from_bytes_be(num_bigint::Sign::Plus, &recipient_pubkey_bytes[0..8]);
        let ext_data_hash = self.compute_ext_data_hash(&recipient_num, amount)?;

        // Build witness inputs
        let path_bigint: Vec<BigInt> = path_elements.iter().map(|e| fr_to_bigint(e)).collect();
        let zero_path: Vec<BigInt> = (0..MERKLE_TREE_HEIGHT).map(|_| BigInt::from(0)).collect();

        let mut inputs: HashMap<String, Vec<BigInt>> = HashMap::new();
        inputs.insert("root".to_string(), vec![fr_to_bigint(&root)]);
        inputs.insert("publicAmount".to_string(), vec![public_amount_bigint]);
        inputs.insert("extDataHash".to_string(), vec![ext_data_hash]);
        inputs.insert("mintAddress".to_string(), vec![BigInt::from(1)]);
        inputs.insert("inputNullifier".to_string(), vec![
            fr_to_bigint(&nullifier1),
            fr_to_bigint(&nullifier2),
        ]);
        inputs.insert("inAmount".to_string(), vec![BigInt::from(amount), BigInt::from(0)]);
        // NOTE: Both inputs use the same private key (utxo owner)
        inputs.insert("inPrivateKey".to_string(), vec![
            str_to_bigint(&utxo.privkey)?,
            str_to_bigint(&utxo.privkey)?,  // Same privkey for dummy input
        ]);
        inputs.insert("inBlinding".to_string(), vec![
            str_to_bigint(&utxo.blinding)?,
            fr_to_bigint(&dummy_blinding),
        ]);
        inputs.insert("inPathIndices".to_string(), vec![
            BigInt::from(leaf_index as u64),
            BigInt::from(0),
        ]);
        inputs.insert("inPathElements".to_string(), [path_bigint, zero_path].concat());
        inputs.insert("outputCommitment".to_string(), vec![
            fr_to_bigint(&out_commitment1),
            fr_to_bigint(&out_commitment2),
        ]);
        inputs.insert("outAmount".to_string(), vec![BigInt::from(0), BigInt::from(0)]);
        // NOTE: Both outputs use the same pubkey (utxo owner)
        inputs.insert("outPubkey".to_string(), vec![
            str_to_bigint(&utxo.pubkey)?,
            str_to_bigint(&utxo.pubkey)?,  // Same pubkey for both outputs
        ]);
        inputs.insert("outBlinding".to_string(), vec![
            fr_to_bigint(&out_blinding1),
            fr_to_bigint(&out_blinding2),
        ]);

        let (proof, public_signals) = self.generate_proof(inputs)?;
        self.format_proof(&proof, &public_signals)
    }

    /// Generate proof using witness calculator and arkworks
    fn generate_proof(&self, inputs: HashMap<String, Vec<BigInt>>) -> Result<(Proof<Bn254>, Vec<Fr>)> {
        // Create witness calculator
        let mut store = Store::default();
        let mut wtns = WitnessCalculator::new(&mut store, &self.wasm_path)
            .map_err(|e| anyhow!("Failed to load witness calculator: {:?}", e))?;

        // Calculate witness
        let full_assignment = wtns
            .calculate_witness_element::<Fr, _>(&mut store, inputs, false)
            .map_err(|e| anyhow!("Witness calculation failed: {:?}", e))?;

        // Generate proof
        let mut rng = thread_rng();
        let r = Fr::rand(&mut rng);
        let s = Fr::rand(&mut rng);

        let num_inputs = self.matrices.num_instance_variables;
        let num_constraints = self.matrices.num_constraints;

        let proof = Groth16::<Bn254, CircomReduction>::create_proof_with_reduction_and_matrices(
            &self.params,
            r,
            s,
            &self.matrices,
            num_inputs,
            num_constraints,
            full_assignment.as_slice(),
        )
        .map_err(|e| anyhow!("Proof generation failed: {:?}", e))?;

        let public_signals: Vec<Fr> = full_assignment[1..num_inputs].to_vec();

        Ok((proof, public_signals))
    }

    /// Compute extDataHash using Poseidon
    fn compute_ext_data_hash(&self, recipient_num: &BigInt, amount: u64) -> Result<BigInt> {
        use light_poseidon::{Poseidon, PoseidonHasher};

        let mut hasher = Poseidon::<Fr>::new_circom(2)
            .map_err(|e| anyhow!("Poseidon init failed: {:?}", e))?;

        let recipient_fr = bigint_to_fr(recipient_num)?;
        let amount_fr = Fr::from(amount);

        let hash = hasher
            .hash(&[recipient_fr, amount_fr])
            .map_err(|e| anyhow!("Poseidon hash failed: {:?}", e))?;

        Ok(fr_to_bigint(&hash))
    }

    /// Format proof for on-chain submission
    fn format_proof(
        &self,
        proof: &Proof<Bn254>,
        public_signals: &[Fr],
    ) -> Result<TransactProofData> {
        let modulus = num_bigint::BigUint::parse_bytes(BN254_FIELD_MODULUS.as_bytes(), 10).unwrap();
        let public_amount = public_signal_to_i64(&public_signals[1])?;

        // Negate proof_a for pairing check
        let a_x = g1_x_to_biguint(&proof.a);
        let a_y = g1_y_to_biguint(&proof.a);
        let neg_y = (&modulus - &a_y) % &modulus;

        let proof_a = [biguint_to_be_32(&a_x), biguint_to_be_32(&neg_y)].concat();

        // G2 point: x1_be || x0_be || y1_be || y0_be
        let (b_x0, b_x1) = g2_x_to_biguint(&proof.b);
        let (b_y0, b_y1) = g2_y_to_biguint(&proof.b);
        let proof_b = [
            biguint_to_be_32(&b_x1),
            biguint_to_be_32(&b_x0),
            biguint_to_be_32(&b_y1),
            biguint_to_be_32(&b_y0),
        ].concat();

        let c_x = g1_x_to_biguint(&proof.c);
        let c_y = g1_y_to_biguint(&proof.c);
        let proof_c = [biguint_to_be_32(&c_x), biguint_to_be_32(&c_y)].concat();

        // Public signals: root, publicAmount, extDataHash, null1, null2, commit1, commit2
        let root = fr_to_be_bytes(&public_signals[0]).to_vec();
        let nullifier1 = fr_to_be_bytes(&public_signals[3]).to_vec();
        let nullifier2 = fr_to_be_bytes(&public_signals[4]).to_vec();
        let commitment1 = fr_to_be_bytes(&public_signals[5]).to_vec();
        let commitment2 = fr_to_be_bytes(&public_signals[6]).to_vec();
        let ext_data_hash = fr_to_be_bytes(&public_signals[2]).to_vec();

        Ok(TransactProofData {
            proof_a,
            proof_b,
            proof_c,
            root,
            nullifier1,
            nullifier2,
            commitment1,
            commitment2,
            public_amount,
            ext_data_hash,
        })
    }
}

fn public_signal_to_i64(signal: &Fr) -> Result<i64> {
    let field = BigInt::parse_bytes(FIELD_SIZE.as_bytes(), 10)
        .ok_or_else(|| anyhow!("Invalid FIELD_SIZE"))?;
    let value = fr_to_bigint(signal);
    let half_field = &field >> 1;
    let signed = if value > half_field {
        value - &field
    } else {
        value
    };
    signed
        .to_i64()
        .ok_or_else(|| anyhow!("public amount out of i64 range"))
}

/// Proof data formatted for on-chain transaction
#[derive(Debug, Clone)]
pub struct TransactProofData {
    pub proof_a: Vec<u8>,
    pub proof_b: Vec<u8>,
    pub proof_c: Vec<u8>,
    pub root: Vec<u8>,
    pub nullifier1: Vec<u8>,
    pub nullifier2: Vec<u8>,
    pub commitment1: Vec<u8>,
    pub commitment2: Vec<u8>,
    pub public_amount: i64,
    pub ext_data_hash: Vec<u8>,
}

impl TransactProofData {
    /// Build instruction data for transact
    pub fn to_instruction_data(&self) -> Vec<u8> {
        let mut data = Vec::with_capacity(8 + 256 + 32 * 5 + 8 + 32);

        // Discriminator
        data.extend_from_slice(&[217, 149, 130, 143, 221, 52, 252, 119]);

        // Proof (256 bytes)
        data.extend_from_slice(&self.proof_a);
        data.extend_from_slice(&self.proof_b);
        data.extend_from_slice(&self.proof_c);

        // Public inputs
        data.extend_from_slice(&self.root);
        data.extend_from_slice(&self.nullifier1);
        data.extend_from_slice(&self.nullifier2);
        data.extend_from_slice(&self.commitment1);
        data.extend_from_slice(&self.commitment2);

        // Public amount as i64 little-endian
        data.extend_from_slice(&self.public_amount.to_le_bytes());

        // Ext data hash
        data.extend_from_slice(&self.ext_data_hash);

        data
    }
}

// Helper functions
fn fr_to_bigint(f: &Fr) -> BigInt {
    let bytes = f.into_bigint().to_bytes_le();
    BigInt::from_bytes_le(num_bigint::Sign::Plus, &bytes)
}

fn bigint_to_fr(n: &BigInt) -> Result<Fr> {
    let (_, bytes) = n.to_bytes_le();
    let mut arr = [0u8; 32];
    let len = bytes.len().min(32);
    arr[..len].copy_from_slice(&bytes[..len]);
    Ok(Fr::from_le_bytes_mod_order(&arr))
}

fn str_to_bigint(s: &str) -> Result<BigInt> {
    BigInt::parse_bytes(s.as_bytes(), 10)
        .ok_or_else(|| anyhow!("Invalid bigint string: {}", s))
}

fn g1_x_to_biguint(p: &G1Affine) -> num_bigint::BigUint {
    let bytes = p.x.into_bigint().to_bytes_le();
    num_bigint::BigUint::from_bytes_le(&bytes)
}

fn g1_y_to_biguint(p: &G1Affine) -> num_bigint::BigUint {
    let bytes = p.y.into_bigint().to_bytes_le();
    num_bigint::BigUint::from_bytes_le(&bytes)
}

fn g2_x_to_biguint(p: &G2Affine) -> (num_bigint::BigUint, num_bigint::BigUint) {
    let x0_bytes = p.x.c0.into_bigint().to_bytes_le();
    let x1_bytes = p.x.c1.into_bigint().to_bytes_le();
    (
        num_bigint::BigUint::from_bytes_le(&x0_bytes),
        num_bigint::BigUint::from_bytes_le(&x1_bytes),
    )
}

fn g2_y_to_biguint(p: &G2Affine) -> (num_bigint::BigUint, num_bigint::BigUint) {
    let y0_bytes = p.y.c0.into_bigint().to_bytes_le();
    let y1_bytes = p.y.c1.into_bigint().to_bytes_le();
    (
        num_bigint::BigUint::from_bytes_le(&y0_bytes),
        num_bigint::BigUint::from_bytes_le(&y1_bytes),
    )
}

fn biguint_to_be_32(n: &num_bigint::BigUint) -> Vec<u8> {
    let bytes = n.to_bytes_be();
    let mut result = vec![0u8; 32];
    let start = 32 - bytes.len().min(32);
    result[start..].copy_from_slice(&bytes[..bytes.len().min(32)]);
    result
}
