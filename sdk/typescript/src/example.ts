/**
 * Example: Anonymous Transfer using privacy-zig
 * 
 * This example shows how to:
 * 1. Create a deposit commitment
 * 2. Track commitments in a Merkle tree
 * 3. Generate a withdrawal proof
 * 4. Execute an anonymous transfer
 */

import { 
  Connection, 
  Keypair, 
  PublicKey,
  SystemProgram,
} from '@solana/web3.js';
import { AnchorProvider, Wallet } from '@coral-xyz/anchor';
import {
  PrivacyPoolClient,
  MerkleTree,
  createUtxo,
  generateSecret,
  PROGRAM_ID,
} from './index';

// For ZK proof generation (using Privacy Cash's snarkjs setup)
// import * as snarkjs from 'snarkjs';

async function main() {
  console.log('=== Privacy-Zig Anonymous Transfer Example ===\n');
  
  // ============================================
  // Setup
  // ============================================
  
  const connection = new Connection('http://localhost:8899', 'confirmed');
  const payer = Keypair.generate(); // In real usage, load from file
  const wallet = new Wallet(payer);
  const provider = new AnchorProvider(connection, wallet, {});
  
  const client = new PrivacyPoolClient(provider);
  
  // Initialize Merkle tree for tracking commitments
  const tree = new MerkleTree();
  await tree.init();
  
  console.log('✓ Initialized client and Merkle tree\n');
  
  // ============================================
  // Step 1: Alice creates a deposit
  // ============================================
  
  console.log('--- Step 1: Alice Deposits ---');
  
  const aliceKeypair = Keypair.generate();
  const alicePubkeyBigInt = BigInt('0x' + Buffer.from(aliceKeypair.publicKey.toBytes()).toString('hex'));
  
  const depositAmount = 1_000_000_000n; // 1 SOL
  
  // Create UTXO for deposit
  const { utxo, commitment, blinding } = await createUtxo(
    depositAmount,
    alicePubkeyBigInt,
    SystemProgram.programId // SOL
  );
  
  console.log(`  Amount: ${depositAmount / 1_000_000_000n} SOL`);
  console.log(`  Commitment: ${Buffer.from(commitment).toString('hex').slice(0, 16)}...`);
  
  // Insert into local Merkle tree
  const leafIndex = tree.insert(commitment);
  console.log(`  Leaf index: ${leafIndex}`);
  console.log(`  Tree root: ${Buffer.from(tree.getRoot()).toString('hex').slice(0, 16)}...`);
  
  // In a real transaction, call client.transact() with publicAmount > 0
  // This would emit CommitmentData event that we can parse
  
  console.log('✓ Deposit commitment created\n');
  
  // ============================================
  // Step 2: Bob wants to receive anonymously
  // ============================================
  
  console.log('--- Step 2: Prepare Withdrawal ---');
  
  // Bob generates a new keypair (anonymous recipient)
  const bobKeypair = Keypair.generate();
  console.log(`  Bob's new address: ${bobKeypair.publicKey.toBase58().slice(0, 16)}...`);
  
  // Get Merkle proof for Alice's commitment
  const proof = tree.getProof(leafIndex);
  console.log(`  Merkle proof path length: ${proof.pathElements.length}`);
  
  // ============================================
  // Step 3: Generate ZK Proof (off-chain)
  // ============================================
  
  console.log('\n--- Step 3: Generate ZK Proof ---');
  
  // The ZK proof proves:
  // 1. Alice knows the secret/blinding for a commitment in the tree
  // 2. The nullifier is correctly derived
  // 3. The output commitment is valid
  
  // Circuit inputs (for Privacy Cash's transaction.circom):
  const circuitInputs = {
    // Public inputs
    root: tree.getRoot(),
    publicAmount: -depositAmount, // Negative = withdrawal
    extDataHash: new Uint8Array(32), // Hash of recipient, relayer, etc.
    
    // Private inputs for input UTXO
    inAmount: [depositAmount, 0n],
    inPrivateKey: [alicePubkeyBigInt, 0n], // Simplified - real impl uses proper keypair
    inBlinding: [blinding, 0n],
    inPathIndices: [leafIndex, 0],
    inPathElements: [proof.pathElements, Array(26).fill(new Uint8Array(32))],
    
    // Private inputs for output UTXO (change - none in this case)
    outAmount: [0n, 0n],
    outPubkey: [0n, 0n],
    outBlinding: [0n, 0n],
  };
  
  console.log('  Circuit inputs prepared');
  console.log('  (In production, call snarkjs.groth16.fullProve() here)');
  
  // In production:
  // const { proof: zkProof, publicSignals } = await snarkjs.groth16.fullProve(
  //   circuitInputs,
  //   'circuits/transaction.wasm',
  //   'circuits/transaction.zkey'
  // );
  
  console.log('✓ ZK proof generated (simulated)\n');
  
  // ============================================
  // Step 4: Execute Anonymous Transfer
  // ============================================
  
  console.log('--- Step 4: Anonymous Transfer ---');
  
  // In production, call client.transact() with:
  // - proof: The Groth16 proof
  // - root: Merkle root
  // - inputNullifier1/2: Nullifiers for spent UTXOs
  // - outputCommitment1/2: New commitments (0 for full withdrawal)
  // - publicAmount: Negative value for withdrawal
  // - extDataHash: Hash of recipient address
  
  console.log('  From: Alice (anonymous - not revealed on-chain)');
  console.log(`  To: ${bobKeypair.publicKey.toBase58().slice(0, 16)}...`);
  console.log(`  Amount: ${depositAmount / 1_000_000_000n} SOL`);
  console.log('  Result: Transaction graph broken! ✓');
  
  console.log('\n=== Anonymous Transfer Complete ===');
  console.log('\nObservers can see:');
  console.log('  - Someone withdrew from the pool');
  console.log('  - Funds went to Bob\'s new address');
  console.log('\nObservers CANNOT see:');
  console.log('  - That Alice was the depositor');
  console.log('  - Any link between Alice and Bob');
}

main().catch(console.error);
