/**
 * Privacy Pool Client Library
 * 
 * Pure client-side implementation for anonymous transfers on Solana.
 * No indexer or server required!
 */

import { 
  Connection, 
  PublicKey, 
  SystemProgram,
  Transaction,
  TransactionInstruction,
  ComputeBudgetProgram,
  LAMPORTS_PER_SOL,
} from '@solana/web3.js';
import { buildPoseidon } from 'circomlibjs';
import { groth16 } from 'snarkjs';
// @ts-ignore
import { utils } from 'ffjavascript';
import BN from 'bn.js';

// ============================================================================
// Constants
// ============================================================================

export const PROGRAM_ID = new PublicKey('Dz82AAVPumnUys5SQ8HMat5iD6xiBVMGC2xJiJdZkpbT');
export const MERKLE_TREE_HEIGHT = 26;
export const FIELD_SIZE = new BN('21888242871839275222246405745257275088548364400416034343698204186575808495617');
export const BN254_FIELD_MODULUS = BigInt('21888242871839275222246405745257275088696311157297823662689037894645226208583');

// Instruction discriminators
const TRANSACT_DISCRIMINATOR = new Uint8Array([217, 149, 130, 143, 221, 52, 252, 119]);

// Pool configuration (testnet)
export const POOL_CONFIG = {
  treeAccount: new PublicKey('2h8oJdtfe9AE8r3Dmp49iBruUMfQQMmo6r63q79vxUN1'),
  globalConfig: new PublicKey('9qQELDcp6Z48tLpsDs6RtSQbYx5GpquxB4staTKQz15i'),
  feeRecipient: new PublicKey('FM7WTd5Hr7ppp6vu3M4uAspF4DoRjrYPPFvAmqB7H95D'),
};

// ============================================================================
// Types
// ============================================================================

export interface DepositNote {
  commitment: string;
  amount: number;
  privkey: string;
  pubkey: string;
  blinding: string;
  leafIndex: number;
  timestamp: number;
}

export interface WithdrawResult {
  success: boolean;
  signature?: string;
  error?: string;
}

// ============================================================================
// Poseidon Hash
// ============================================================================

let poseidonInstance: any = null;

export async function getPoseidon() {
  if (!poseidonInstance) {
    poseidonInstance = await buildPoseidon();
  }
  return poseidonInstance;
}

export function poseidonHash(poseidon: any, inputs: bigint[]): bigint {
  const hash = poseidon(inputs);
  return poseidon.F.toObject(hash);
}

// ============================================================================
// Utility Functions
// ============================================================================

function generateRandom31Bytes(): Uint8Array {
  const bytes = new Uint8Array(31);
  if (typeof window !== 'undefined' && window.crypto) {
    window.crypto.getRandomValues(bytes);
  } else {
    // Node.js fallback
    for (let i = 0; i < 31; i++) {
      bytes[i] = Math.floor(Math.random() * 256);
    }
  }
  return bytes;
}

function generateBlinding(): bigint {
  const bytes = generateRandom31Bytes();
  return BigInt('0x' + Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join(''));
}

function generateKeypair(poseidon: any): { privkey: bigint; pubkey: bigint } {
  const privkeyBytes = generateRandom31Bytes();
  const privkey = BigInt('0x' + Array.from(privkeyBytes).map(b => b.toString(16).padStart(2, '0')).join(''));
  const pubkey = poseidonHash(poseidon, [privkey]);
  return { privkey, pubkey };
}

// ============================================================================
// Merkle Tree
// ============================================================================

export class MerkleTree {
  height: number;
  zeros: bigint[] = [];
  leaves: bigint[] = [];
  layers: bigint[][] = [];
  private poseidon: any;
  
  constructor(height: number = MERKLE_TREE_HEIGHT) {
    this.height = height;
  }
  
  async init() {
    this.poseidon = await getPoseidon();
    this.zeros = this.computeZeroHashes();
  }
  
  private computeZeroHashes(): bigint[] {
    const zeros: bigint[] = [0n];
    for (let i = 1; i <= this.height; i++) {
      zeros.push(poseidonHash(this.poseidon, [zeros[i - 1], zeros[i - 1]]));
    }
    return zeros;
  }
  
  insert(leaf: bigint) {
    this.leaves.push(leaf);
    this.rebuildTree();
  }
  
  private rebuildTree() {
    this.layers = [this.leaves.slice()];
    
    for (let level = 0; level < this.height; level++) {
      const currentLayer = this.layers[level];
      const nextLayer: bigint[] = [];
      
      for (let i = 0; i < currentLayer.length; i += 2) {
        const left = currentLayer[i];
        const right = i + 1 < currentLayer.length ? currentLayer[i + 1] : this.zeros[level];
        nextLayer.push(poseidonHash(this.poseidon, [left, right]));
      }
      
      if (nextLayer.length === 0) {
        nextLayer.push(this.zeros[level + 1]);
      }
      
      this.layers.push(nextLayer);
    }
  }
  
  getRoot(): bigint {
    if (this.layers.length === 0) return this.zeros[this.height];
    return this.layers[this.layers.length - 1][0];
  }
  
  getPath(leafIndex: number): { pathElements: bigint[]; pathIndices: number[] } {
    const pathElements: bigint[] = [];
    const pathIndices: number[] = [];
    
    let currentIndex = leafIndex;
    
    for (let level = 0; level < this.height; level++) {
      const isRight = currentIndex % 2 === 1;
      const siblingIndex = isRight ? currentIndex - 1 : currentIndex + 1;
      
      pathIndices.push(isRight ? 1 : 0);
      
      const currentLayer = this.layers[level] || [];
      if (siblingIndex < currentLayer.length) {
        pathElements.push(currentLayer[siblingIndex]);
      } else {
        pathElements.push(this.zeros[level]);
      }
      
      currentIndex = Math.floor(currentIndex / 2);
    }
    
    return { pathElements, pathIndices };
  }
  
  findLeafIndex(commitment: bigint): number {
    return this.leaves.findIndex(l => l === commitment);
  }
}

// ============================================================================
// Proof Formatting (for on-chain verification)
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
// Chain Data Fetching
// ============================================================================

export async function fetchCommitmentsFromChain(
  connection: Connection,
): Promise<bigint[]> {
  const signatures = await connection.getSignaturesForAddress(POOL_CONFIG.treeAccount, { limit: 1000 });
  
  const commitments: bigint[] = [];
  
  for (const sigInfo of signatures.reverse()) {
    try {
      const tx = await connection.getTransaction(sigInfo.signature, {
        commitment: 'confirmed',
        maxSupportedTransactionVersion: 0,
      });
      
      if (!tx || !tx.meta || tx.meta.err) continue;
      
      const message = tx.transaction.message;
      const instructions = 'compiledInstructions' in message 
        ? message.compiledInstructions 
        : [];
      
      for (const ix of instructions) {
        const progIdIndex = ix.programIdIndex;
        const accountKeys = 'staticAccountKeys' in message 
          ? message.staticAccountKeys 
          : [];
        
        if (accountKeys[progIdIndex]?.equals(PROGRAM_ID)) {
          const data = Buffer.from(ix.data);
          
          if (data.length >= 424 && 
              data[0] === TRANSACT_DISCRIMINATOR[0] && 
              data[1] === TRANSACT_DISCRIMINATOR[1]) {
            const commitment1Bytes = data.slice(360, 392);
            const commitment2Bytes = data.slice(392, 424);
            
            const c1 = BigInt('0x' + commitment1Bytes.toString('hex'));
            const c2 = BigInt('0x' + commitment2Bytes.toString('hex'));
            
            commitments.push(c1, c2);
          }
        }
      }
    } catch (e) {
      // Skip failed transactions
    }
  }
  
  return commitments;
}

export async function getCurrentLeafIndex(connection: Connection): Promise<number> {
  const treeInfo = await connection.getAccountInfo(POOL_CONFIG.treeAccount);
  if (!treeInfo) throw new Error('Tree account not found');
  return Number(treeInfo.data.readBigUInt64LE(40));
}

// ============================================================================
// Deposit
// ============================================================================

export async function prepareDeposit(
  connection: Connection,
  payerPubkey: PublicKey,
  amountLamports: number,
): Promise<{
  transaction: Transaction;
  note: DepositNote;
}> {
  const poseidon = await getPoseidon();
  const solMintAddress = 1n;
  
  // Generate UTXO keypair
  const utxoKeypair = generateKeypair(poseidon);
  
  // Create dummy inputs (for fresh deposit)
  const dummyBlinding1 = generateBlinding();
  const dummyBlinding2 = generateBlinding();
  
  const dummyCommitment1 = poseidonHash(poseidon, [0n, utxoKeypair.pubkey, dummyBlinding1, solMintAddress]);
  const dummyCommitment2 = poseidonHash(poseidon, [0n, utxoKeypair.pubkey, dummyBlinding2, solMintAddress]);
  
  const dummySig1 = poseidonHash(poseidon, [utxoKeypair.privkey, dummyCommitment1, 0n]);
  const dummySig2 = poseidonHash(poseidon, [utxoKeypair.privkey, dummyCommitment2, 0n]);
  
  const inputNullifier1 = poseidonHash(poseidon, [dummyCommitment1, 0n, dummySig1]);
  const inputNullifier2 = poseidonHash(poseidon, [dummyCommitment2, 0n, dummySig2]);
  
  // Create output commitments
  const outBlinding1 = generateBlinding();
  const outBlinding2 = generateBlinding();
  
  const outputCommitment1 = poseidonHash(poseidon, [BigInt(amountLamports), utxoKeypair.pubkey, outBlinding1, solMintAddress]);
  const outputCommitment2 = poseidonHash(poseidon, [0n, utxoKeypair.pubkey, outBlinding2, solMintAddress]);
  
  // Get empty tree root
  const tree = new MerkleTree();
  await tree.init();
  const root = tree.zeros[MERKLE_TREE_HEIGHT];
  
  // Compute public amount and extDataHash
  const publicAmount = new BN(amountLamports).add(FIELD_SIZE).mod(FIELD_SIZE);
  const payerPubkeyNum = BigInt('0x' + payerPubkey.toBuffer().toString('hex').slice(0, 16));
  const extDataHash = poseidonHash(poseidon, [payerPubkeyNum, BigInt(amountLamports)]);
  
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
  const wasmPath = '/circuits/transaction2.wasm';
  const zkeyPath = '/circuits/transaction2.zkey';
  
  const { proof, publicSignals } = await groth16.fullProve(
    utils.stringifyBigInts(proofInput),
    wasmPath,
    zkeyPath
  );
  
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
  
  Buffer.from(TRANSACT_DISCRIMINATOR).copy(instructionData, offset); offset += 8;
  proofBuffer.copy(instructionData, offset); offset += 256;
  Buffer.from(publicInputsBytes[0]).copy(instructionData, offset); offset += 32; // root
  Buffer.from(publicInputsBytes[3]).copy(instructionData, offset); offset += 32; // nullifier1
  Buffer.from(publicInputsBytes[4]).copy(instructionData, offset); offset += 32; // nullifier2
  Buffer.from(publicInputsBytes[5]).copy(instructionData, offset); offset += 32; // commitment1
  Buffer.from(publicInputsBytes[6]).copy(instructionData, offset); offset += 32; // commitment2
  
  const publicAmountI64 = Buffer.alloc(8);
  publicAmountI64.writeBigInt64LE(BigInt(amountLamports), 0);
  publicAmountI64.copy(instructionData, offset); offset += 8;
  
  Buffer.from(publicInputsBytes[2]).copy(instructionData, offset);
  
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
      { pubkey: POOL_CONFIG.treeAccount, isSigner: false, isWritable: true },
      { pubkey: nullifier1PDA, isSigner: false, isWritable: true },
      { pubkey: nullifier2PDA, isSigner: false, isWritable: true },
      { pubkey: POOL_CONFIG.globalConfig, isSigner: false, isWritable: false },
      { pubkey: poolVault, isSigner: false, isWritable: true },
      { pubkey: payerPubkey, isSigner: true, isWritable: true },
      { pubkey: POOL_CONFIG.feeRecipient, isSigner: false, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    programId: PROGRAM_ID,
    data: instructionData,
  });
  
  const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({
    units: 1_400_000,
  });
  
  const transaction = new Transaction().add(computeBudgetIx).add(transactIx);
  
  // Get current leaf index
  const currentLeafIndex = await getCurrentLeafIndex(connection);
  
  // Create note
  const note: DepositNote = {
    commitment: outputCommitment1.toString(),
    amount: amountLamports,
    privkey: utxoKeypair.privkey.toString(),
    pubkey: utxoKeypair.pubkey.toString(),
    blinding: outBlinding1.toString(),
    leafIndex: currentLeafIndex,
    timestamp: Date.now(),
  };
  
  return { transaction, note };
}

// ============================================================================
// Withdraw
// ============================================================================

export async function prepareWithdraw(
  connection: Connection,
  note: DepositNote,
  recipientPubkey: PublicKey,
  payerPubkey: PublicKey,
): Promise<Transaction> {
  const poseidon = await getPoseidon();
  const solMintAddress = 1n;
  
  const privkey = BigInt(note.privkey);
  const pubkey = BigInt(note.pubkey);
  const blinding = BigInt(note.blinding);
  const commitment = BigInt(note.commitment);
  const withdrawAmount = note.amount;
  
  // Fetch commitments and rebuild tree
  const commitments = await fetchCommitmentsFromChain(connection);
  const tree = new MerkleTree();
  await tree.init();
  for (const c of commitments) {
    tree.insert(c);
  }
  
  // Find our commitment
  const actualLeafIndex = tree.findLeafIndex(commitment);
  if (actualLeafIndex === -1) {
    throw new Error('Commitment not found in tree');
  }
  
  // Get Merkle path
  const { pathElements, pathIndices } = tree.getPath(actualLeafIndex);
  
  // Compute nullifier
  const signature = poseidonHash(poseidon, [privkey, commitment, BigInt(actualLeafIndex)]);
  const inputNullifier = poseidonHash(poseidon, [commitment, BigInt(actualLeafIndex), signature]);
  
  // Dummy second input
  const dummyBlinding = generateBlinding();
  const dummyCommitment = poseidonHash(poseidon, [0n, pubkey, dummyBlinding, solMintAddress]);
  const dummySig = poseidonHash(poseidon, [privkey, dummyCommitment, 0n]);
  const dummyNullifier = poseidonHash(poseidon, [dummyCommitment, 0n, dummySig]);
  
  // Output commitments (zero for full withdrawal)
  const outBlinding1 = generateBlinding();
  const outBlinding2 = generateBlinding();
  const outputCommitment1 = poseidonHash(poseidon, [0n, pubkey, outBlinding1, solMintAddress]);
  const outputCommitment2 = poseidonHash(poseidon, [0n, pubkey, outBlinding2, solMintAddress]);
  
  const root = tree.getRoot();
  const publicAmountBN = new BN(withdrawAmount).neg().add(FIELD_SIZE).mod(FIELD_SIZE);
  
  const recipientNum = BigInt('0x' + recipientPubkey.toBuffer().slice(0, 8).toString('hex'));
  const extDataHash = poseidonHash(poseidon, [recipientNum, BigInt(withdrawAmount)]);
  
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
    inPathIndices: [actualLeafIndex, 0],
    inPathElements: [
      pathElements.map(e => e.toString()),
      new Array(MERKLE_TREE_HEIGHT).fill('0'),
    ],
    outputCommitment: [outputCommitment1.toString(), outputCommitment2.toString()],
    outAmount: ['0', '0'],
    outPubkey: [pubkey.toString(), pubkey.toString()],
    outBlinding: [outBlinding1.toString(), outBlinding2.toString()],
  };
  
  // Generate proof
  const wasmPath = '/circuits/transaction2.wasm';
  const zkeyPath = '/circuits/transaction2.zkey';
  
  const { proof, publicSignals } = await groth16.fullProve(
    utils.stringifyBigInts(proofInput),
    wasmPath,
    zkeyPath
  );
  
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
  
  Buffer.from(TRANSACT_DISCRIMINATOR).copy(instructionData, offset); offset += 8;
  proofBuffer.copy(instructionData, offset); offset += 256;
  Buffer.from(publicInputsBytes[0]).copy(instructionData, offset); offset += 32;
  Buffer.from(publicInputsBytes[3]).copy(instructionData, offset); offset += 32;
  Buffer.from(publicInputsBytes[4]).copy(instructionData, offset); offset += 32;
  Buffer.from(publicInputsBytes[5]).copy(instructionData, offset); offset += 32;
  Buffer.from(publicInputsBytes[6]).copy(instructionData, offset); offset += 32;
  
  const publicAmountI64 = Buffer.alloc(8);
  publicAmountI64.writeBigInt64LE(BigInt(-withdrawAmount), 0);
  publicAmountI64.copy(instructionData, offset); offset += 8;
  
  Buffer.from(publicInputsBytes[2]).copy(instructionData, offset);
  
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
  
  const transactIx = new TransactionInstruction({
    keys: [
      { pubkey: POOL_CONFIG.treeAccount, isSigner: false, isWritable: true },
      { pubkey: nullifier1PDA, isSigner: false, isWritable: true },
      { pubkey: nullifier2PDA, isSigner: false, isWritable: true },
      { pubkey: POOL_CONFIG.globalConfig, isSigner: false, isWritable: false },
      { pubkey: poolVault, isSigner: false, isWritable: true },
      { pubkey: payerPubkey, isSigner: true, isWritable: true },
      { pubkey: recipientPubkey, isSigner: false, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    programId: PROGRAM_ID,
    data: instructionData,
  });
  
  const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({
    units: 1_400_000,
  });
  
  return new Transaction().add(computeBudgetIx).add(transactIx);
}

// ============================================================================
// Local Storage
// ============================================================================

const STORAGE_KEY = 'privacy-zig-notes';

export function saveNoteToStorage(note: DepositNote): void {
  if (typeof window === 'undefined') return;
  const notes = getNotesFromStorage();
  notes.push(note);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(notes));
}

export function getNotesFromStorage(): DepositNote[] {
  if (typeof window === 'undefined') return [];
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored ? JSON.parse(stored) : [];
  } catch {
    return [];
  }
}

export function removeNoteFromStorage(commitment: string): void {
  if (typeof window === 'undefined') return;
  const notes = getNotesFromStorage();
  const filtered = notes.filter(n => n.commitment !== commitment);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(filtered));
}

export function exportNote(note: DepositNote): string {
  return btoa(JSON.stringify(note));
}

export function importNote(encoded: string): DepositNote {
  try {
    return JSON.parse(atob(encoded));
  } catch {
    throw new Error('Invalid note format');
  }
}

// ============================================================================
// Pool Stats
// ============================================================================

export async function getPoolStats(connection: Connection): Promise<{
  totalDeposits: number;
  poolBalance: number;
}> {
  const [poolVault] = PublicKey.findProgramAddressSync(
    [Buffer.from('pool_vault')],
    PROGRAM_ID
  );
  
  const [treeInfo, vaultBalance] = await Promise.all([
    connection.getAccountInfo(POOL_CONFIG.treeAccount),
    connection.getBalance(poolVault),
  ]);
  
  const totalDeposits = treeInfo ? Number(treeInfo.data.readBigUInt64LE(40)) / 2 : 0;
  
  return {
    totalDeposits,
    poolBalance: vaultBalance / LAMPORTS_PER_SOL,
  };
}
