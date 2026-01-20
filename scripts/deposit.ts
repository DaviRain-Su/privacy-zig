/**
 * Deposit SOL into Privacy Pool
 * 
 * Usage: npx tsx deposit.ts [amount_in_sol]
 * Default: 0.1 SOL
 */

import {
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
  sendAndConfirmTransaction,
  ComputeBudgetProgram,
  LAMPORTS_PER_SOL,
} from '@solana/web3.js';
import * as fs from 'fs';
import * as path from 'path';
import { groth16 } from 'snarkjs';
import { buildPoseidon } from 'circomlibjs';
// @ts-ignore
import { utils } from 'ffjavascript';
import BN from 'bn.js';
import * as crypto from 'crypto';

// ============================================================================
// Constants
// ============================================================================

const PROGRAM_ID = new PublicKey('Dz82AAVPumnUys5SQ8HMat5iD6xiBVMGC2xJiJdZkpbT');
const MERKLE_TREE_HEIGHT = 26;
const FIELD_SIZE = new BN('21888242871839275222246405745257275088548364400416034343698204186575808495617');
const BN254_FIELD_MODULUS = BigInt('21888242871839275222246405745257275088696311157297823662689037894645226208583');

// Discriminator for transact instruction
const TRANSACT_DISCRIMINATOR = Buffer.from([217, 149, 130, 143, 221, 52, 252, 119]);

// ============================================================================
// Poseidon Hash
// ============================================================================

let poseidon: any = null;

async function getPoseidon() {
  if (!poseidon) {
    poseidon = await buildPoseidon();
  }
  return poseidon;
}

function poseidonHash(inputs: bigint[]): bigint {
  const hash = poseidon(inputs);
  return poseidon.F.toObject(hash);
}

// ============================================================================
// Proof Formatting
// ============================================================================

function negateG1Point(x: bigint, y: bigint): { x: bigint; y: bigint } {
  const negY = (BN254_FIELD_MODULUS - y) % BN254_FIELD_MODULUS;
  return { x, y: negY };
}

function parseProofToBytesArray(proof: any): {
  proofA: number[];
  proofB: number[];
  proofC: number[];
} {
  // Negate proof_a for pairing check
  const piA_x = BigInt(proof.pi_a[0]);
  const piA_y = BigInt(proof.pi_a[1]);
  const negatedA = negateG1Point(piA_x, piA_y);
  
  // Convert to big-endian bytes
  const piA_x_bytes = Array.from(utils.leInt2Buff(negatedA.x, 32)).reverse();
  const piA_y_bytes = Array.from(utils.leInt2Buff(negatedA.y, 32)).reverse();
  
  const piC_x_bytes = Array.from(utils.leInt2Buff(utils.unstringifyBigInts(proof.pi_c[0]), 32)).reverse();
  const piC_y_bytes = Array.from(utils.leInt2Buff(utils.unstringifyBigInts(proof.pi_c[1]), 32)).reverse();
  
  // G2 point format: x1_be || x0_be || y1_be || y0_be
  const piB_x0 = BigInt(proof.pi_b[0][0]);
  const piB_x1 = BigInt(proof.pi_b[0][1]);
  const piB_y0 = BigInt(proof.pi_b[1][0]);
  const piB_y1 = BigInt(proof.pi_b[1][1]);
  
  const piB_x1_be = Array.from(utils.leInt2Buff(piB_x1, 32)).reverse();
  const piB_x0_be = Array.from(utils.leInt2Buff(piB_x0, 32)).reverse();
  const piB_y1_be = Array.from(utils.leInt2Buff(piB_y1, 32)).reverse();
  const piB_y0_be = Array.from(utils.leInt2Buff(piB_y0, 32)).reverse();
  
  return {
    proofA: [...piA_x_bytes, ...piA_y_bytes],
    proofB: [...piB_x1_be, ...piB_x0_be, ...piB_y1_be, ...piB_y0_be],
    proofC: [...piC_x_bytes, ...piC_y_bytes],
  };
}

function parseToBytesArray(publicSignals: string[]): number[][] {
  return publicSignals.map(sig => 
    Array.from(utils.leInt2Buff(utils.unstringifyBigInts(sig), 32)).reverse()
  );
}

// ============================================================================
// UTXO Generation
// ============================================================================

function generateKeypair() {
  const privkeyBytes = crypto.randomBytes(31);
  const privkey = BigInt('0x' + privkeyBytes.toString('hex'));
  const pubkey = poseidonHash([privkey]);
  return { privkey, pubkey };
}

function generateBlinding(): bigint {
  const bytes = crypto.randomBytes(31);
  return BigInt('0x' + bytes.toString('hex'));
}

function computeZeroHashes(): bigint[] {
  const zeros: bigint[] = [0n];
  for (let i = 1; i <= MERKLE_TREE_HEIGHT; i++) {
    zeros.push(poseidonHash([zeros[i - 1], zeros[i - 1]]));
  }
  return zeros;
}

// ============================================================================
// Main Deposit Function
// ============================================================================

async function deposit(amountSol: number) {
  console.log('=== Privacy Pool Deposit ===\n');
  
  // Load config
  const configPath = path.join(__dirname, 'deployed-config.json');
  const config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
  
  // Initialize Poseidon
  await getPoseidon();
  
  // Load keypair
  const keypairPath = process.env.HOME + '/.config/solana/id.json';
  const keypairData = JSON.parse(fs.readFileSync(keypairPath, 'utf-8'));
  const payer = Keypair.fromSecretKey(Uint8Array.from(keypairData));
  
  const connection = new Connection('https://api.testnet.solana.com', 'confirmed');
  const balance = await connection.getBalance(payer.publicKey);
  
  console.log('Payer:', payer.publicKey.toBase58());
  console.log('Balance:', balance / LAMPORTS_PER_SOL, 'SOL');
  console.log('Deposit amount:', amountSol, 'SOL');
  
  const amountLamports = Math.floor(amountSol * LAMPORTS_PER_SOL);
  
  // Generate UTXO keypair
  const utxoKeypair = generateKeypair();
  const solMintAddress = 1n;
  
  // Create dummy inputs (for fresh deposit)
  const dummyBlinding1 = generateBlinding();
  const dummyBlinding2 = generateBlinding();
  
  const dummyCommitment1 = poseidonHash([0n, utxoKeypair.pubkey, dummyBlinding1, solMintAddress]);
  const dummyCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, dummyBlinding2, solMintAddress]);
  
  const dummySig1 = poseidonHash([utxoKeypair.privkey, dummyCommitment1, 0n]);
  const dummySig2 = poseidonHash([utxoKeypair.privkey, dummyCommitment2, 0n]);
  
  const inputNullifier1 = poseidonHash([dummyCommitment1, 0n, dummySig1]);
  const inputNullifier2 = poseidonHash([dummyCommitment2, 0n, dummySig2]);
  
  // Create output commitments
  const outBlinding1 = generateBlinding();
  const outBlinding2 = generateBlinding();
  
  const outputCommitment1 = poseidonHash([BigInt(amountLamports), utxoKeypair.pubkey, outBlinding1, solMintAddress]);
  const outputCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, outBlinding2, solMintAddress]);
  
  // Get empty tree root
  const zeros = computeZeroHashes();
  const root = zeros[MERKLE_TREE_HEIGHT];
  
  // Compute public amount and extDataHash
  const publicAmount = new BN(amountLamports).add(FIELD_SIZE).mod(FIELD_SIZE);
  const payerPubkeyNum = BigInt('0x' + payer.publicKey.toBuffer().toString('hex').slice(0, 16));
  const extDataHash = poseidonHash([payerPubkeyNum, BigInt(amountLamports)]);
  
  // Build circuit input
  const zeroPath = new Array(MERKLE_TREE_HEIGHT).fill('0');
  const proofInput = {
    root: root.toString(),
    publicAmount: publicAmount.toString(),
    extDataHash: extDataHash.toString(),
    mintAddress: solMintAddress.toString(),
    inputNullifier: [inputNullifier1.toString(), inputNullifier2.toString()],
    inAmount: ['0', '0'],
    inPrivateKey: [utxoKeypair.privkey.toString(), utxoKeypair.privkey.toString()],
    inBlinding: [dummyBlinding1.toString(), dummyBlinding2.toString()],
    inPathIndices: [0, 0],
    inPathElements: [zeroPath, zeroPath],
    outputCommitment: [outputCommitment1.toString(), outputCommitment2.toString()],
    outAmount: [amountLamports.toString(), '0'],
    outPubkey: [utxoKeypair.pubkey.toString(), utxoKeypair.pubkey.toString()],
    outBlinding: [outBlinding1.toString(), outBlinding2.toString()],
  };
  
  // Generate ZK proof
  console.log('\nGenerating ZK proof...');
  const wasmPath = path.join(__dirname, '..', 'artifacts', 'transaction2.wasm');
  const zkeyPath = path.join(__dirname, '..', 'artifacts', 'transaction2.zkey');
  
  const { proof, publicSignals } = await groth16.fullProve(
    utils.stringifyBigInts(proofInput),
    wasmPath,
    zkeyPath
  );
  console.log('Proof generated');
  
  // Serialize proof and public inputs
  const proofBytes = parseProofToBytesArray(proof);
  const publicInputsBytes = parseToBytesArray(publicSignals);
  
  const proofBuffer = Buffer.concat([
    Buffer.from(proofBytes.proofA),
    Buffer.from(proofBytes.proofB),
    Buffer.from(proofBytes.proofC),
  ]);
  
  // Build instruction data
  const instructionData = Buffer.alloc(8 + 256 + 32 + 32 + 32 + 32 + 32 + 8 + 32);
  let offset = 0;
  
  TRANSACT_DISCRIMINATOR.copy(instructionData, offset); offset += 8;
  proofBuffer.copy(instructionData, offset); offset += 256;
  Buffer.from(publicInputsBytes[0]).copy(instructionData, offset); offset += 32; // root
  Buffer.from(publicInputsBytes[3]).copy(instructionData, offset); offset += 32; // nullifier1
  Buffer.from(publicInputsBytes[4]).copy(instructionData, offset); offset += 32; // nullifier2
  Buffer.from(publicInputsBytes[5]).copy(instructionData, offset); offset += 32; // commitment1
  Buffer.from(publicInputsBytes[6]).copy(instructionData, offset); offset += 32; // commitment2
  
  const publicAmountI64 = Buffer.alloc(8);
  publicAmountI64.writeBigInt64LE(BigInt(amountLamports), 0);
  publicAmountI64.copy(instructionData, offset); offset += 8;
  
  Buffer.from(publicInputsBytes[2]).copy(instructionData, offset); // extDataHash
  
  // Derive PDAs
  const [nullifier1PDA] = PublicKey.findProgramAddressSync(
    [Buffer.from('nullifier'), Buffer.from(publicInputsBytes[3])],
    PROGRAM_ID
  );
  const [nullifier2PDA] = PublicKey.findProgramAddressSync(
    [Buffer.from('nullifier'), Buffer.from(publicInputsBytes[4])],
    PROGRAM_ID
  );
  const [poolVault] = PublicKey.findProgramAddressSync(
    [Buffer.from('pool_vault')],
    PROGRAM_ID
  );
  
  // Build transaction
  const transactIx = new TransactionInstruction({
    keys: [
      { pubkey: new PublicKey(config.treeAccount), isSigner: false, isWritable: true },
      { pubkey: nullifier1PDA, isSigner: false, isWritable: true },
      { pubkey: nullifier2PDA, isSigner: false, isWritable: true },
      { pubkey: new PublicKey(config.globalConfig), isSigner: false, isWritable: false },
      { pubkey: poolVault, isSigner: false, isWritable: true },
      { pubkey: payer.publicKey, isSigner: true, isWritable: true },
      { pubkey: payer.publicKey, isSigner: false, isWritable: true }, // fee recipient
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    programId: PROGRAM_ID,
    data: instructionData,
  });
  
  const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({
    units: 1_400_000,
  });
  
  const transaction = new Transaction().add(computeBudgetIx).add(transactIx);
  
  // Get current leaf index from tree account before sending
  const treeInfo = await connection.getAccountInfo(new PublicKey(config.treeAccount));
  let currentLeafIndex = 0;
  if (treeInfo) {
    // next_index is at offset 8 (discriminator) + 32 (authority) = 40
    currentLeafIndex = Number(treeInfo.data.readBigUInt64LE(40));
  }
  
  // Send transaction
  console.log('\nSending transaction...');
  
  try {
    const signature = await sendAndConfirmTransaction(
      connection,
      transaction,
      [payer],
      { commitment: 'confirmed' }
    );
    
    console.log('\n✅ Deposit successful!');
    console.log('Signature:', signature);
    console.log('Explorer:', `https://explorer.solana.com/tx/${signature}?cluster=testnet`);
    
    // Save note for future withdrawal
    const note = {
      commitment: outputCommitment1.toString(),
      amount: amountLamports,
      privkey: utxoKeypair.privkey.toString(),
      pubkey: utxoKeypair.pubkey.toString(),
      blinding: outBlinding1.toString(),
      leafIndex: currentLeafIndex, // Actual leaf index from chain
    };
    
    const notePath = path.join(__dirname, `note-${Date.now()}.json`);
    fs.writeFileSync(notePath, JSON.stringify(note, null, 2));
    console.log('\n📝 Note saved to:', notePath);
    console.log('⚠️  Keep this file safe - you need it to withdraw!');
    
  } catch (error: any) {
    console.error('\n❌ Deposit failed:', error.message);
    if (error.logs) {
      console.log('\nProgram logs:');
      error.logs.forEach((log: string) => console.log('  ', log));
    }
  }
}

// Parse command line args
const amountArg = process.argv[2];
const amount = amountArg ? parseFloat(amountArg) : 0.1;

deposit(amount).catch(console.error);
