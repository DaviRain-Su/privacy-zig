/**
 * Privacy Pool Client Library
 * 
 * Provides deposit, withdraw, and anonymous transfer functions.
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
import BN from 'bn.js';
import { buildPoseidon } from 'circomlibjs';
import { addNote, updateNote, Note } from './notes';

// ============================================================================
// Constants
// ============================================================================

export const PROGRAM_ID = new PublicKey('Dz82AAVPumnUys5SQ8HMat5iD6xiBVMGC2xJiJdZkpbT');
export const MERKLE_TREE_HEIGHT = 26;
export const FIELD_SIZE = new BN('21888242871839275222246405745257275088548364400416034343698204186575808495617');
export const BN254_FIELD_MODULUS = BigInt('21888242871839275222246405745257275088696311157297823662689037894645226208583');

const TRANSACT_DISCRIMINATOR = new Uint8Array([217, 149, 130, 143, 221, 52, 252, 119]);

export const POOL_CONFIG = {
  treeAccount: new PublicKey('2h8oJdtfe9AE8r3Dmp49iBruUMfQQMmo6r63q79vxUN1'),
  globalConfig: new PublicKey('9qQELDcp6Z48tLpsDs6RtSQbYx5GpquxB4staTKQz15i'),
  feeRecipient: new PublicKey('FM7WTd5Hr7ppp6vu3M4uAspF4DoRjrYPPFvAmqB7H95D'),
};

// ============================================================================
// Poseidon Hash (circomlibjs 0.1.7 - async API)
// ============================================================================

let poseidonInstance: any = null;

export async function initPoseidon(): Promise<void> {
  if (poseidonInstance) return;
  poseidonInstance = await buildPoseidon();
}

export function poseidonHash(inputs: bigint[]): bigint {
  if (!poseidonInstance) throw new Error('Poseidon not initialized');
  const hash = poseidonInstance(inputs);
  return poseidonInstance.F.toObject(hash);
}

// ============================================================================
// Utils
// ============================================================================

function generateRandom31Bytes(): Uint8Array {
  const bytes = new Uint8Array(31);
  if (typeof window !== 'undefined' && window.crypto) {
    window.crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < 31; i++) {
      bytes[i] = Math.floor(Math.random() * 256);
    }
  }
  return bytes;
}

function bytesToBigInt(bytes: Uint8Array): bigint {
  return BigInt('0x' + Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join(''));
}

function bigintToHex(n: bigint): string {
  return n.toString(16).padStart(62, '0');
}

function hexToBigint(hex: string): bigint {
  return BigInt('0x' + hex);
}

export function generateBlinding(): bigint {
  return bytesToBigInt(generateRandom31Bytes());
}

export function generateKeypair(): { privkey: bigint; pubkey: bigint } {
  const privkey = bytesToBigInt(generateRandom31Bytes());
  const pubkey = poseidonHash([privkey]);
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
  
  constructor(height: number = MERKLE_TREE_HEIGHT) {
    this.height = height;
    this.zeros = [0n];
    for (let i = 1; i <= this.height; i++) {
      this.zeros.push(poseidonHash([this.zeros[i - 1], this.zeros[i - 1]]));
    }
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
        nextLayer.push(poseidonHash([left, right]));
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
      pathElements.push(siblingIndex < currentLayer.length ? currentLayer[siblingIndex] : this.zeros[level]);
      currentIndex = Math.floor(currentIndex / 2);
    }
    
    return { pathElements, pathIndices };
  }
  
  findLeafIndex(commitment: bigint): number {
    return this.leaves.findIndex(l => l === commitment);
  }
}

// ============================================================================
// Proof Generation (using snarkjs)
// ============================================================================

function negateG1Point(x: bigint, y: bigint): { x: bigint; y: bigint } {
  return { x, y: (BN254_FIELD_MODULUS - y) % BN254_FIELD_MODULUS };
}

async function generateProof(proofInput: any): Promise<{ proof: any; publicSignals: string[] }> {
  const snarkjs = await import('snarkjs');
  const ffjavascript = await import('ffjavascript');
  
  return await snarkjs.groth16.fullProve(
    ffjavascript.utils.stringifyBigInts(proofInput),
    '/circuits/transaction2.wasm',
    '/circuits/transaction2.zkey'
  );
}

async function serializeProof(proof: any): Promise<Buffer> {
  const ffjavascript = await import('ffjavascript');
  const { utils } = ffjavascript;
  
  const piA_x = BigInt(proof.pi_a[0]);
  const piA_y = BigInt(proof.pi_a[1]);
  const negA = negateG1Point(piA_x, piA_y);
  
  const proofA = [
    ...Array.from(utils.leInt2Buff(negA.x, 32)).reverse(),
    ...Array.from(utils.leInt2Buff(negA.y, 32)).reverse(),
  ];
  
  const proofB = [
    ...Array.from(utils.leInt2Buff(BigInt(proof.pi_b[0][1]), 32)).reverse(),
    ...Array.from(utils.leInt2Buff(BigInt(proof.pi_b[0][0]), 32)).reverse(),
    ...Array.from(utils.leInt2Buff(BigInt(proof.pi_b[1][1]), 32)).reverse(),
    ...Array.from(utils.leInt2Buff(BigInt(proof.pi_b[1][0]), 32)).reverse(),
  ];
  
  const proofC = [
    ...Array.from(utils.leInt2Buff(BigInt(proof.pi_c[0]), 32)).reverse(),
    ...Array.from(utils.leInt2Buff(BigInt(proof.pi_c[1]), 32)).reverse(),
  ];
  
  return Buffer.concat([Buffer.from(proofA), Buffer.from(proofB), Buffer.from(proofC)]);
}

async function serializePublicSignals(publicSignals: string[]): Promise<Buffer[]> {
  const ffjavascript = await import('ffjavascript');
  const { utils } = ffjavascript;
  
  return publicSignals.map(sig => 
    Buffer.from(Array.from(utils.leInt2Buff(utils.unstringifyBigInts(sig), 32)).reverse())
  );
}

// ============================================================================
// Chain Interaction
// ============================================================================

export async function fetchCommitmentsFromChain(connection: Connection): Promise<bigint[]> {
  const signatures = await connection.getSignaturesForAddress(POOL_CONFIG.treeAccount, { limit: 1000 });
  const commitments: bigint[] = [];
  
  for (const sigInfo of signatures.reverse()) {
    try {
      const tx = await connection.getTransaction(sigInfo.signature, {
        commitment: 'confirmed',
        maxSupportedTransactionVersion: 0,
      });
      
      if (!tx?.meta || tx.meta.err) continue;
      
      const message = tx.transaction.message;
      const instructions = 'compiledInstructions' in message ? message.compiledInstructions : [];
      
      for (const ix of instructions) {
        const accountKeys = 'staticAccountKeys' in message ? message.staticAccountKeys : [];
        if (!accountKeys[ix.programIdIndex]?.equals(PROGRAM_ID)) continue;
        
        const data = Buffer.from(ix.data);
        if (data.length >= 424 && data[0] === TRANSACT_DISCRIMINATOR[0]) {
          commitments.push(
            BigInt('0x' + data.slice(360, 392).toString('hex')),
            BigInt('0x' + data.slice(392, 424).toString('hex'))
          );
        }
      }
    } catch {}
  }
  
  return commitments;
}

export async function getCurrentLeafIndex(connection: Connection): Promise<number> {
  const treeInfo = await connection.getAccountInfo(POOL_CONFIG.treeAccount);
  if (!treeInfo) throw new Error('Tree account not found');
  return Number(treeInfo.data.readBigUInt64LE(40));
}

// ============================================================================
// Progress Types
// ============================================================================

export interface TransferProgress {
  step: 'init' | 'deposit-proof' | 'deposit-tx' | 'withdraw-proof' | 'withdraw-tx' | 'done';
  message: string;
}

export interface DepositResult {
  success: boolean;
  note?: Note;
  signature?: string;
  error?: string;
}

export interface WithdrawResult {
  success: boolean;
  signature?: string;
  error?: string;
}

// ============================================================================
// Deposit Function
// ============================================================================

export async function deposit(
  connection: Connection,
  senderPubkey: PublicKey,
  amountLamports: number,
  sendTransaction: (tx: Transaction, connection: Connection) => Promise<string>,
  onProgress?: (msg: string) => void,
): Promise<DepositResult> {
  try {
    onProgress?.('Initializing...');
    await initPoseidon();
    
    const solMintAddress = 1n;
    const utxoKeypair = generateKeypair();
    const currentLeafIndex = await getCurrentLeafIndex(connection);
    
    // Build empty tree for root
    const tree = new MerkleTree();
    const emptyRoot = tree.zeros[MERKLE_TREE_HEIGHT];
    
    onProgress?.('Generating proof...');
    
    // Dummy inputs
    const dummyBlinding1 = generateBlinding();
    const dummyBlinding2 = generateBlinding();
    const dummyCommitment1 = poseidonHash([0n, utxoKeypair.pubkey, dummyBlinding1, solMintAddress]);
    const dummyCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, dummyBlinding2, solMintAddress]);
    const dummySig1 = poseidonHash([utxoKeypair.privkey, dummyCommitment1, 0n]);
    const dummySig2 = poseidonHash([utxoKeypair.privkey, dummyCommitment2, 0n]);
    const inputNullifier1 = poseidonHash([dummyCommitment1, 0n, dummySig1]);
    const inputNullifier2 = poseidonHash([dummyCommitment2, 0n, dummySig2]);
    
    // Output commitment (the one we'll save)
    const outBlinding1 = generateBlinding();
    const outBlinding2 = generateBlinding();
    const outputCommitment1 = poseidonHash([BigInt(amountLamports), utxoKeypair.pubkey, outBlinding1, solMintAddress]);
    const outputCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, outBlinding2, solMintAddress]);
    
    const depositPublicAmount = new BN(amountLamports).add(FIELD_SIZE).mod(FIELD_SIZE);
    const senderNum = BigInt('0x' + senderPubkey.toBuffer().toString('hex').slice(0, 16));
    const depositExtDataHash = poseidonHash([senderNum, BigInt(amountLamports)]);
    
    const zeroPath = new Array(MERKLE_TREE_HEIGHT).fill('0');
    const depositInput = {
      root: emptyRoot.toString(),
      publicAmount: depositPublicAmount.toString(),
      extDataHash: depositExtDataHash.toString(),
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
    
    const proofResult = await generateProof(depositInput);
    const proofBuffer = await serializeProof(proofResult.proof);
    const publicInputs = await serializePublicSignals(proofResult.publicSignals);
    
    // Build instruction
    const depositData = Buffer.alloc(8 + 256 + 32 * 5 + 8 + 32);
    let offset = 0;
    Buffer.from(TRANSACT_DISCRIMINATOR).copy(depositData, offset); offset += 8;
    proofBuffer.copy(depositData, offset); offset += 256;
    publicInputs[0].copy(depositData, offset); offset += 32;
    publicInputs[3].copy(depositData, offset); offset += 32;
    publicInputs[4].copy(depositData, offset); offset += 32;
    publicInputs[5].copy(depositData, offset); offset += 32;
    publicInputs[6].copy(depositData, offset); offset += 32;
    depositData.writeBigInt64LE(BigInt(amountLamports), offset); offset += 8;
    publicInputs[2].copy(depositData, offset);
    
    const [null1PDA] = PublicKey.findProgramAddressSync([Buffer.from('nullifier'), publicInputs[3]], PROGRAM_ID);
    const [null2PDA] = PublicKey.findProgramAddressSync([Buffer.from('nullifier'), publicInputs[4]], PROGRAM_ID);
    const [poolVault] = PublicKey.findProgramAddressSync([Buffer.from('pool_vault')], PROGRAM_ID);
    
    const depositIx = new TransactionInstruction({
      keys: [
        { pubkey: POOL_CONFIG.treeAccount, isSigner: false, isWritable: true },
        { pubkey: null1PDA, isSigner: false, isWritable: true },
        { pubkey: null2PDA, isSigner: false, isWritable: true },
        { pubkey: POOL_CONFIG.globalConfig, isSigner: false, isWritable: false },
        { pubkey: poolVault, isSigner: false, isWritable: true },
        { pubkey: senderPubkey, isSigner: true, isWritable: true },
        { pubkey: POOL_CONFIG.feeRecipient, isSigner: false, isWritable: true },
        { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
      ],
      programId: PROGRAM_ID,
      data: depositData,
    });
    
    onProgress?.('Sending transaction...');
    
    const tx = new Transaction()
      .add(ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }))
      .add(depositIx);
    
    const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();
    tx.recentBlockhash = blockhash;
    tx.feePayer = senderPubkey;
    
    const signature = await sendTransaction(tx, connection);
    
    onProgress?.('Confirming...');
    await connection.confirmTransaction({ signature, blockhash, lastValidBlockHeight });
    
    // Save note to localStorage
    const note = addNote({
      amount: amountLamports,
      privkey: bigintToHex(utxoKeypair.privkey),
      pubkey: utxoKeypair.pubkey.toString(),
      blinding: outBlinding1.toString(),
      commitment: outputCommitment1.toString(),
      leafIndex: currentLeafIndex, // Will be updated when we verify
      status: 'deposited',
      depositTxSig: signature,
    });
    
    return { success: true, note, signature };
    
  } catch (error: any) {
    console.error('Deposit error:', error);
    return { success: false, error: error.message };
  }
}

// ============================================================================
// Withdraw Function
// ============================================================================

export async function withdraw(
  connection: Connection,
  senderPubkey: PublicKey,
  recipientAddress: string,
  note: Note,
  sendTransaction: (tx: Transaction, connection: Connection) => Promise<string>,
  onProgress?: (msg: string) => void,
): Promise<WithdrawResult> {
  try {
    onProgress?.('Initializing...');
    await initPoseidon();
    
    const solMintAddress = 1n;
    const recipientPubkey = new PublicKey(recipientAddress);
    const amountLamports = note.amount;
    
    // Restore keypair from note
    const privkey = hexToBigint(note.privkey);
    const pubkey = BigInt(note.pubkey);
    const blinding = BigInt(note.blinding);
    const commitment = BigInt(note.commitment);
    
    onProgress?.('Fetching Merkle tree...');
    
    // Fetch commitments and build tree
    const commitments = await fetchCommitmentsFromChain(connection);
    const tree = new MerkleTree();
    for (const c of commitments) {
      tree.insert(c);
    }
    
    // Find leaf index
    let leafIndex = tree.findLeafIndex(commitment);
    if (leafIndex === -1) {
      // Use stored index as fallback
      leafIndex = note.leafIndex;
      if (leafIndex === -1) {
        return { success: false, error: 'Commitment not found in tree' };
      }
    }
    
    const { pathElements } = tree.getPath(leafIndex);
    const root = tree.getRoot();
    
    onProgress?.('Generating proof...');
    
    // Compute nullifier
    const sig = poseidonHash([privkey, commitment, BigInt(leafIndex)]);
    const nullifier = poseidonHash([commitment, BigInt(leafIndex), sig]);
    
    // Dummy second input
    const dummyBlinding = generateBlinding();
    const dummyCommitment = poseidonHash([0n, pubkey, dummyBlinding, solMintAddress]);
    const dummySig = poseidonHash([privkey, dummyCommitment, 0n]);
    const dummyNullifier = poseidonHash([dummyCommitment, 0n, dummySig]);
    
    // Zero outputs
    const outBlinding1 = generateBlinding();
    const outBlinding2 = generateBlinding();
    const outputCommitment1 = poseidonHash([0n, pubkey, outBlinding1, solMintAddress]);
    const outputCommitment2 = poseidonHash([0n, pubkey, outBlinding2, solMintAddress]);
    
    const withdrawPublicAmount = new BN(amountLamports).neg().add(FIELD_SIZE).mod(FIELD_SIZE);
    const recipientNum = BigInt('0x' + recipientPubkey.toBuffer().slice(0, 8).toString('hex'));
    const extDataHash = poseidonHash([recipientNum, BigInt(amountLamports)]);
    
    const withdrawInput = {
      root: root.toString(),
      publicAmount: withdrawPublicAmount.toString(),
      extDataHash: extDataHash.toString(),
      mintAddress: solMintAddress.toString(),
      inputNullifier: [nullifier.toString(), dummyNullifier.toString()],
      inAmount: [amountLamports.toString(), '0'],
      inPrivateKey: [privkey.toString(), privkey.toString()],
      inBlinding: [blinding.toString(), dummyBlinding.toString()],
      inPathIndices: [leafIndex, 0],
      inPathElements: [
        pathElements.map(e => e.toString()),
        new Array(MERKLE_TREE_HEIGHT).fill('0'),
      ],
      outputCommitment: [outputCommitment1.toString(), outputCommitment2.toString()],
      outAmount: ['0', '0'],
      outPubkey: [pubkey.toString(), pubkey.toString()],
      outBlinding: [outBlinding1.toString(), outBlinding2.toString()],
    };
    
    const proofResult = await generateProof(withdrawInput);
    const proofBuffer = await serializeProof(proofResult.proof);
    const publicInputs = await serializePublicSignals(proofResult.publicSignals);
    
    // Build instruction
    const withdrawData = Buffer.alloc(8 + 256 + 32 * 5 + 8 + 32);
    let offset = 0;
    Buffer.from(TRANSACT_DISCRIMINATOR).copy(withdrawData, offset); offset += 8;
    proofBuffer.copy(withdrawData, offset); offset += 256;
    publicInputs[0].copy(withdrawData, offset); offset += 32;
    publicInputs[3].copy(withdrawData, offset); offset += 32;
    publicInputs[4].copy(withdrawData, offset); offset += 32;
    publicInputs[5].copy(withdrawData, offset); offset += 32;
    publicInputs[6].copy(withdrawData, offset); offset += 32;
    withdrawData.writeBigInt64LE(BigInt(-amountLamports), offset); offset += 8;
    publicInputs[2].copy(withdrawData, offset);
    
    const [null1PDA] = PublicKey.findProgramAddressSync([Buffer.from('nullifier'), publicInputs[3]], PROGRAM_ID);
    const [null2PDA] = PublicKey.findProgramAddressSync([Buffer.from('nullifier'), publicInputs[4]], PROGRAM_ID);
    const [poolVault] = PublicKey.findProgramAddressSync([Buffer.from('pool_vault')], PROGRAM_ID);
    
    const withdrawIx = new TransactionInstruction({
      keys: [
        { pubkey: POOL_CONFIG.treeAccount, isSigner: false, isWritable: true },
        { pubkey: null1PDA, isSigner: false, isWritable: true },
        { pubkey: null2PDA, isSigner: false, isWritable: true },
        { pubkey: POOL_CONFIG.globalConfig, isSigner: false, isWritable: false },
        { pubkey: poolVault, isSigner: false, isWritable: true },
        { pubkey: senderPubkey, isSigner: true, isWritable: true },
        { pubkey: recipientPubkey, isSigner: false, isWritable: true },
        { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
      ],
      programId: PROGRAM_ID,
      data: withdrawData,
    });
    
    onProgress?.('Sending transaction...');
    
    const tx = new Transaction()
      .add(ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }))
      .add(withdrawIx);
    
    const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();
    tx.recentBlockhash = blockhash;
    tx.feePayer = senderPubkey;
    
    const signature = await sendTransaction(tx, connection);
    
    onProgress?.('Confirming...');
    await connection.confirmTransaction({ signature, blockhash, lastValidBlockHeight });
    
    // Update note status
    updateNote(note.id, { status: 'withdrawn', withdrawTxSig: signature });
    
    return { success: true, signature };
    
  } catch (error: any) {
    console.error('Withdraw error:', error);
    return { success: false, error: error.message };
  }
}

// ============================================================================
// Pool Stats
// ============================================================================

export async function getPoolStats(connection: Connection): Promise<{
  totalDeposits: number;
  poolBalance: number;
}> {
  const [poolVault] = PublicKey.findProgramAddressSync([Buffer.from('pool_vault')], PROGRAM_ID);
  
  const [treeInfo, vaultBalance] = await Promise.all([
    connection.getAccountInfo(POOL_CONFIG.treeAccount),
    connection.getBalance(poolVault),
  ]);
  
  return {
    totalDeposits: treeInfo ? Number(treeInfo.data.readBigUInt64LE(40)) / 2 : 0,
    poolBalance: vaultBalance / LAMPORTS_PER_SOL,
  };
}
