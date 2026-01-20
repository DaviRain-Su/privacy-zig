/**
 * Withdraw SOL from Privacy Pool
 * 
 * Usage: npx tsx withdraw.ts <note-file> [recipient]
 * If recipient is not specified, withdraws to the payer's wallet
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
  const piA_x = BigInt(proof.pi_a[0]);
  const piA_y = BigInt(proof.pi_a[1]);
  const negatedA = negateG1Point(piA_x, piA_y);
  
  const piA_x_bytes = Array.from(utils.leInt2Buff(negatedA.x, 32)).reverse();
  const piA_y_bytes = Array.from(utils.leInt2Buff(negatedA.y, 32)).reverse();
  
  const piC_x_bytes = Array.from(utils.leInt2Buff(utils.unstringifyBigInts(proof.pi_c[0]), 32)).reverse();
  const piC_y_bytes = Array.from(utils.leInt2Buff(utils.unstringifyBigInts(proof.pi_c[1]), 32)).reverse();
  
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
// Merkle Tree Utils
// ============================================================================

function computeZeroHashes(): bigint[] {
  const zeros: bigint[] = [0n];
  for (let i = 1; i <= MERKLE_TREE_HEIGHT; i++) {
    zeros.push(poseidonHash([zeros[i - 1], zeros[i - 1]]));
  }
  return zeros;
}

function generateBlinding(): bigint {
  const bytes = crypto.randomBytes(31);
  return BigInt('0x' + bytes.toString('hex'));
}

// Build Merkle path from chain events (simplified - assumes we have the commitments)
async function buildMerklePath(
  connection: Connection,
  treeAccount: PublicKey,
  leafIndex: number,
  commitment: bigint,
): Promise<{ pathElements: string[]; pathIndices: number[] }> {
  // Read tree data
  const treeInfo = await connection.getAccountInfo(treeAccount);
  if (!treeInfo) throw new Error('Tree account not found');
  
  const zeros = computeZeroHashes();
  
  // For now, build a simple path assuming this is the only leaf
  // In production, you'd need to reconstruct the tree from all commitments
  const pathElements: string[] = [];
  const pathIndices: number[] = [];
  
  let currentIndex = leafIndex;
  for (let level = 0; level < MERKLE_TREE_HEIGHT; level++) {
    const isRight = currentIndex % 2 === 1;
    pathIndices.push(isRight ? 1 : 0);
    
    // Get sibling - if no sibling exists, use zero hash
    // This is simplified - real implementation needs to track all leaves
    pathElements.push(zeros[level].toString());
    
    currentIndex = Math.floor(currentIndex / 2);
  }
  
  return { pathElements, pathIndices };
}

// ============================================================================
// Main Withdraw Function
// ============================================================================

async function withdraw(notePath: string, recipientAddress?: string) {
  console.log('=== Privacy Pool Withdrawal ===\n');
  
  // Load note
  if (!fs.existsSync(notePath)) {
    console.error('Note file not found:', notePath);
    process.exit(1);
  }
  
  const note = JSON.parse(fs.readFileSync(notePath, 'utf-8'));
  console.log('Note loaded:');
  console.log('  Amount:', note.amount / LAMPORTS_PER_SOL, 'SOL');
  console.log('  Leaf Index:', note.leafIndex);
  
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
  
  console.log('\nPayer:', payer.publicKey.toBase58());
  console.log('Balance:', balance / LAMPORTS_PER_SOL, 'SOL');
  
  const recipient = recipientAddress ? new PublicKey(recipientAddress) : payer.publicKey;
  console.log('Recipient:', recipient.toBase58());
  
  const withdrawAmount = note.amount;
  const solMintAddress = 1n;
  
  // Reconstruct the input UTXO
  const privkey = BigInt(note.privkey);
  const pubkey = BigInt(note.pubkey);
  const blinding = BigInt(note.blinding);
  const commitment = BigInt(note.commitment);
  
  // Compute nullifier for the input
  const signature = poseidonHash([privkey, commitment, BigInt(note.leafIndex)]);
  const inputNullifier = poseidonHash([commitment, BigInt(note.leafIndex), signature]);
  
  // Create dummy second input (zero amount)
  const dummyBlinding = generateBlinding();
  const dummyCommitment = poseidonHash([0n, pubkey, dummyBlinding, solMintAddress]);
  const dummySig = poseidonHash([privkey, dummyCommitment, 0n]);
  const dummyNullifier = poseidonHash([dummyCommitment, 0n, dummySig]);
  
  // Create output commitments (both zero for full withdrawal)
  const outBlinding1 = generateBlinding();
  const outBlinding2 = generateBlinding();
  const outputCommitment1 = poseidonHash([0n, pubkey, outBlinding1, solMintAddress]);
  const outputCommitment2 = poseidonHash([0n, pubkey, outBlinding2, solMintAddress]);
  
  // Get Merkle path
  const { pathElements, pathIndices } = await buildMerklePath(
    connection,
    new PublicKey(config.treeAccount),
    note.leafIndex,
    commitment,
  );
  
  // Get current root from chain
  const treeInfo = await connection.getAccountInfo(new PublicKey(config.treeAccount));
  if (!treeInfo) throw new Error('Tree account not found');
  
  // Read root_index and get the current root
  const rootIndex = Number(treeInfo.data.readBigUInt64LE(48));
  const rootOffset = 79 + (rootIndex * 32); // 79 is where root_history starts
  const currentRoot = treeInfo.data.slice(rootOffset, rootOffset + 32);
  const root = BigInt('0x' + Buffer.from(currentRoot).toString('hex'));
  
  console.log('\nCurrent root index:', rootIndex);
  console.log('Root:', root.toString(16));
  
  // Public amount (negative for withdrawal)
  const publicAmountBN = new BN(withdrawAmount).neg().add(FIELD_SIZE).mod(FIELD_SIZE);
  
  // ExtData hash
  const recipientNum = BigInt('0x' + recipient.toBuffer().toString('hex').slice(0, 16));
  const extDataHash = poseidonHash([recipientNum, BigInt(withdrawAmount)]);
  
  // Build proof input
  const proofInput = {
    root: root.toString(),
    publicAmount: publicAmountBN.toString(),
    extDataHash: extDataHash.toString(),
    mintAddress: solMintAddress.toString(),
    inputNullifier: [inputNullifier.toString(), dummyNullifier.toString()],
    inAmount: [withdrawAmount.toString(), '0'],
    inPrivateKey: [privkey.toString(), privkey.toString()],
    inBlinding: [blinding.toString(), dummyBlinding.toString()],
    inPathIndices: [note.leafIndex, 0],
    inPathElements: [pathElements, new Array(MERKLE_TREE_HEIGHT).fill('0')],
    outputCommitment: [outputCommitment1.toString(), outputCommitment2.toString()],
    outAmount: ['0', '0'],
    outPubkey: [pubkey.toString(), pubkey.toString()],
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
  
  // Serialize
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
  
  // public_amount as i64 (negative)
  const publicAmountI64 = Buffer.alloc(8);
  publicAmountI64.writeBigInt64LE(BigInt(-withdrawAmount), 0);
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
      { pubkey: recipient, isSigner: false, isWritable: true }, // recipient for withdrawal
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    programId: PROGRAM_ID,
    data: instructionData,
  });
  
  const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({
    units: 1_400_000,
  });
  
  const transaction = new Transaction().add(computeBudgetIx).add(transactIx);
  
  console.log('\nSending transaction...');
  
  try {
    const signature = await sendAndConfirmTransaction(
      connection,
      transaction,
      [payer],
      { commitment: 'confirmed' }
    );
    
    console.log('\n✅ Withdrawal successful!');
    console.log('Amount:', withdrawAmount / LAMPORTS_PER_SOL, 'SOL');
    console.log('Signature:', signature);
    console.log('Explorer:', `https://explorer.solana.com/tx/${signature}?cluster=testnet`);
    
    // Delete the used note
    fs.unlinkSync(notePath);
    console.log('\n🗑️  Note file deleted (nullifier spent)');
    
  } catch (error: any) {
    console.error('\n❌ Withdrawal failed:', error.message);
    if (error.logs) {
      console.log('\nProgram logs:');
      error.logs.forEach((log: string) => console.log('  ', log));
    }
  }
}

// Parse command line args
const noteFile = process.argv[2];
const recipient = process.argv[3];

if (!noteFile) {
  console.log('Usage: npx tsx withdraw.ts <note-file> [recipient]');
  process.exit(1);
}

withdraw(noteFile, recipient).catch(console.error);
