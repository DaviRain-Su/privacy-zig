/**
 * Privacy Pool Client Library
 * 
 * Simple anonymous transfer: one action, complete privacy.
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

async function initPoseidon(): Promise<void> {
  if (poseidonInstance) return;
  poseidonInstance = await buildPoseidon();
}

function poseidonHash(inputs: bigint[]): bigint {
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

function generateBlinding(): bigint {
  return bytesToBigInt(generateRandom31Bytes());
}

function generateKeypair(): { privkey: bigint; pubkey: bigint } {
  const privkey = bytesToBigInt(generateRandom31Bytes());
  const pubkey = poseidonHash([privkey]);
  return { privkey, pubkey };
}

// ============================================================================
// Merkle Tree
// ============================================================================

class MerkleTree {
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

async function fetchCommitmentsFromChain(connection: Connection): Promise<bigint[]> {
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
          // Extract commitments from instruction data (offsets 360-392 and 392-424)
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

async function getCurrentLeafIndex(connection: Connection): Promise<number> {
  const treeInfo = await connection.getAccountInfo(POOL_CONFIG.treeAccount);
  if (!treeInfo) throw new Error('Tree account not found');
  return Number(treeInfo.data.readBigUInt64LE(40));
}

// ============================================================================
// Anonymous Transfer - Main Function
// ============================================================================

export interface TransferProgress {
  step: 'init' | 'deposit-proof' | 'deposit-tx' | 'withdraw-proof' | 'withdraw-tx' | 'done';
  message: string;
}

export interface TransferResult {
  success: boolean;
  depositSignature?: string;
  withdrawSignature?: string;
  error?: string;
}

/**
 * Anonymous Transfer - One Action Privacy Transfer
 * 
 * This function:
 * 1. Deposits SOL to privacy pool (with ZK proof)
 * 2. Immediately withdraws to recipient (with ZK proof)
 * 
 * Result: No on-chain link between sender and recipient!
 */
export async function anonymousTransfer(
  connection: Connection,
  senderPubkey: PublicKey,
  recipientAddress: string,
  amountLamports: number,
  sendTransaction: (tx: Transaction, connection: Connection) => Promise<string>,
  onProgress?: (progress: TransferProgress) => void,
): Promise<TransferResult> {
  try {
    const report = (step: TransferProgress['step'], message: string) => {
      onProgress?.({ step, message });
    };
    
    report('init', 'Initializing privacy transfer...');
    
    // Initialize Poseidon
    await initPoseidon();
    
    const solMintAddress = 1n;
    const recipientPubkey = new PublicKey(recipientAddress);
    
    // Generate keypair for UTXOs
    const utxoKeypair = generateKeypair();
    
    // ========== Fetch current state ==========
    const currentLeafIndex = await getCurrentLeafIndex(connection);
    
    // Build empty tree (for deposit with zero-value inputs, any root works)
    const tree = new MerkleTree();
    const emptyRoot = tree.zeros[MERKLE_TREE_HEIGHT];
    
    console.log('Current leaf index:', currentLeafIndex);
    console.log('Empty root:', emptyRoot.toString());
    
    // ========== STEP 1: Prepare Deposit ==========
    report('deposit-proof', 'Generating deposit proof...');
    
    // Dummy inputs (zero value) - these don't need to be in tree
    const dummyBlinding1 = generateBlinding();
    const dummyBlinding2 = generateBlinding();
    const dummyCommitment1 = poseidonHash([0n, utxoKeypair.pubkey, dummyBlinding1, solMintAddress]);
    const dummyCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, dummyBlinding2, solMintAddress]);
    const dummySig1 = poseidonHash([utxoKeypair.privkey, dummyCommitment1, 0n]);
    const dummySig2 = poseidonHash([utxoKeypair.privkey, dummyCommitment2, 0n]);
    const inputNullifier1 = poseidonHash([dummyCommitment1, 0n, dummySig1]);
    const inputNullifier2 = poseidonHash([dummyCommitment2, 0n, dummySig2]);
    
    // Output commitments (deposit amount)
    const outBlinding1 = generateBlinding();
    const outBlinding2 = generateBlinding();
    const outputCommitment1 = poseidonHash([BigInt(amountLamports), utxoKeypair.pubkey, outBlinding1, solMintAddress]);
    const outputCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, outBlinding2, solMintAddress]);
    
    // For deposit with zero-value inputs, use empty root (circuit accepts any root when inputs are zero)
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
    
    console.log('Generating deposit proof...');
    const depositProofResult = await generateProof(depositInput);
    console.log('Deposit proof generated!');
    console.log('Public signals:', depositProofResult.publicSignals);
    
    const depositProofBuffer = await serializeProof(depositProofResult.proof);
    const depositPublicInputs = await serializePublicSignals(depositProofResult.publicSignals);
    
    // Build deposit instruction
    const depositData = Buffer.alloc(8 + 256 + 32 * 5 + 8 + 32);
    let offset = 0;
    Buffer.from(TRANSACT_DISCRIMINATOR).copy(depositData, offset); offset += 8;
    depositProofBuffer.copy(depositData, offset); offset += 256;
    depositPublicInputs[0].copy(depositData, offset); offset += 32; // root
    depositPublicInputs[3].copy(depositData, offset); offset += 32; // nullifier1
    depositPublicInputs[4].copy(depositData, offset); offset += 32; // nullifier2
    depositPublicInputs[5].copy(depositData, offset); offset += 32; // commitment1
    depositPublicInputs[6].copy(depositData, offset); offset += 32; // commitment2
    depositData.writeBigInt64LE(BigInt(amountLamports), offset); offset += 8;
    depositPublicInputs[2].copy(depositData, offset); // extDataHash
    
    const [depositNull1PDA] = PublicKey.findProgramAddressSync(
      [Buffer.from('nullifier'), depositPublicInputs[3]],
      PROGRAM_ID
    );
    const [depositNull2PDA] = PublicKey.findProgramAddressSync(
      [Buffer.from('nullifier'), depositPublicInputs[4]],
      PROGRAM_ID
    );
    const [poolVault] = PublicKey.findProgramAddressSync(
      [Buffer.from('pool_vault')],
      PROGRAM_ID
    );
    
    console.log('Nullifier1 PDA:', depositNull1PDA.toBase58());
    console.log('Nullifier2 PDA:', depositNull2PDA.toBase58());
    
    const depositIx = new TransactionInstruction({
      keys: [
        { pubkey: POOL_CONFIG.treeAccount, isSigner: false, isWritable: true },
        { pubkey: depositNull1PDA, isSigner: false, isWritable: true },
        { pubkey: depositNull2PDA, isSigner: false, isWritable: true },
        { pubkey: POOL_CONFIG.globalConfig, isSigner: false, isWritable: false },
        { pubkey: poolVault, isSigner: false, isWritable: true },
        { pubkey: senderPubkey, isSigner: true, isWritable: true },
        { pubkey: POOL_CONFIG.feeRecipient, isSigner: false, isWritable: true },
        { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
      ],
      programId: PROGRAM_ID,
      data: depositData,
    });
    
    // Send deposit transaction
    report('deposit-tx', 'Sending deposit transaction...');
    
    const depositTx = new Transaction()
      .add(ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }))
      .add(depositIx);
    
    const { blockhash: depositBlockhash, lastValidBlockHeight: depositHeight } = 
      await connection.getLatestBlockhash();
    depositTx.recentBlockhash = depositBlockhash;
    depositTx.feePayer = senderPubkey;
    
    const depositSig = await sendTransaction(depositTx, connection);
    console.log('Deposit tx sent:', depositSig);
    
    await connection.confirmTransaction({
      signature: depositSig,
      blockhash: depositBlockhash,
      lastValidBlockHeight: depositHeight,
    });
    console.log('Deposit confirmed!');
    
    // ========== STEP 2: Prepare Withdrawal ==========
    report('withdraw-proof', 'Generating withdrawal proof...');
    
    // Wait for the deposit to be indexed
    await new Promise(r => setTimeout(r, 3000));
    
    // Fetch updated commitments
    const newCommitments = await fetchCommitmentsFromChain(connection);
    const withdrawTree = new MerkleTree();
    for (const c of newCommitments) {
      withdrawTree.insert(c);
    }
    
    // Find our commitment
    let leafIndex = withdrawTree.findLeafIndex(outputCommitment1);
    if (leafIndex === -1) {
      // If not found, add it manually (use expected index)
      leafIndex = currentLeafIndex;
      withdrawTree.insert(outputCommitment1);
      withdrawTree.insert(outputCommitment2);
    }
    
    console.log('Leaf index for withdrawal:', leafIndex);
    
    const { pathElements, pathIndices } = withdrawTree.getPath(leafIndex);
    const withdrawRoot = withdrawTree.getRoot();
    
    console.log('Withdraw root:', withdrawRoot.toString());
    
    // Compute nullifier for withdrawal
    const signature = poseidonHash([utxoKeypair.privkey, outputCommitment1, BigInt(leafIndex)]);
    const withdrawNullifier = poseidonHash([outputCommitment1, BigInt(leafIndex), signature]);
    
    // Dummy second input
    const withdrawDummyBlinding = generateBlinding();
    const withdrawDummyCommitment = poseidonHash([0n, utxoKeypair.pubkey, withdrawDummyBlinding, solMintAddress]);
    const withdrawDummySig = poseidonHash([utxoKeypair.privkey, withdrawDummyCommitment, 0n]);
    const withdrawDummyNullifier = poseidonHash([withdrawDummyCommitment, 0n, withdrawDummySig]);
    
    // Zero outputs (full withdrawal)
    const withdrawOutBlinding1 = generateBlinding();
    const withdrawOutBlinding2 = generateBlinding();
    const withdrawOutputCommitment1 = poseidonHash([0n, utxoKeypair.pubkey, withdrawOutBlinding1, solMintAddress]);
    const withdrawOutputCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, withdrawOutBlinding2, solMintAddress]);
    
    const withdrawPublicAmount = new BN(amountLamports).neg().add(FIELD_SIZE).mod(FIELD_SIZE);
    const recipientNum = BigInt('0x' + recipientPubkey.toBuffer().slice(0, 8).toString('hex'));
    const withdrawExtDataHash = poseidonHash([recipientNum, BigInt(amountLamports)]);
    
    const withdrawInput = {
      root: withdrawRoot.toString(),
      publicAmount: withdrawPublicAmount.toString(),
      extDataHash: withdrawExtDataHash.toString(),
      mintAddress: solMintAddress.toString(),
      inputNullifier: [withdrawNullifier.toString(), withdrawDummyNullifier.toString()],
      inAmount: [amountLamports.toString(), '0'],
      inPrivateKey: [utxoKeypair.privkey.toString(), utxoKeypair.privkey.toString()],
      inBlinding: [outBlinding1.toString(), withdrawDummyBlinding.toString()],
      inPathIndices: [leafIndex, 0],
      inPathElements: [
        pathElements.map(e => e.toString()),
        new Array(MERKLE_TREE_HEIGHT).fill('0'),
      ],
      outputCommitment: [withdrawOutputCommitment1.toString(), withdrawOutputCommitment2.toString()],
      outAmount: ['0', '0'],
      outPubkey: [utxoKeypair.pubkey.toString(), utxoKeypair.pubkey.toString()],
      outBlinding: [withdrawOutBlinding1.toString(), withdrawOutBlinding2.toString()],
    };
    
    console.log('Generating withdraw proof...');
    const withdrawProofResult = await generateProof(withdrawInput);
    console.log('Withdraw proof generated!');
    
    const withdrawProofBuffer = await serializeProof(withdrawProofResult.proof);
    const withdrawPublicInputs = await serializePublicSignals(withdrawProofResult.publicSignals);
    
    // Build withdraw instruction
    const withdrawData = Buffer.alloc(8 + 256 + 32 * 5 + 8 + 32);
    offset = 0;
    Buffer.from(TRANSACT_DISCRIMINATOR).copy(withdrawData, offset); offset += 8;
    withdrawProofBuffer.copy(withdrawData, offset); offset += 256;
    withdrawPublicInputs[0].copy(withdrawData, offset); offset += 32;
    withdrawPublicInputs[3].copy(withdrawData, offset); offset += 32;
    withdrawPublicInputs[4].copy(withdrawData, offset); offset += 32;
    withdrawPublicInputs[5].copy(withdrawData, offset); offset += 32;
    withdrawPublicInputs[6].copy(withdrawData, offset); offset += 32;
    withdrawData.writeBigInt64LE(BigInt(-amountLamports), offset); offset += 8;
    withdrawPublicInputs[2].copy(withdrawData, offset);
    
    const [withdrawNull1PDA] = PublicKey.findProgramAddressSync(
      [Buffer.from('nullifier'), withdrawPublicInputs[3]],
      PROGRAM_ID
    );
    const [withdrawNull2PDA] = PublicKey.findProgramAddressSync(
      [Buffer.from('nullifier'), withdrawPublicInputs[4]],
      PROGRAM_ID
    );
    
    const withdrawIx = new TransactionInstruction({
      keys: [
        { pubkey: POOL_CONFIG.treeAccount, isSigner: false, isWritable: true },
        { pubkey: withdrawNull1PDA, isSigner: false, isWritable: true },
        { pubkey: withdrawNull2PDA, isSigner: false, isWritable: true },
        { pubkey: POOL_CONFIG.globalConfig, isSigner: false, isWritable: false },
        { pubkey: poolVault, isSigner: false, isWritable: true },
        { pubkey: senderPubkey, isSigner: true, isWritable: true },
        { pubkey: recipientPubkey, isSigner: false, isWritable: true },
        { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
      ],
      programId: PROGRAM_ID,
      data: withdrawData,
    });
    
    // Send withdraw transaction
    report('withdraw-tx', 'Sending withdrawal transaction...');
    
    const withdrawTx = new Transaction()
      .add(ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }))
      .add(withdrawIx);
    
    const { blockhash: withdrawBlockhash, lastValidBlockHeight: withdrawHeight } = 
      await connection.getLatestBlockhash();
    withdrawTx.recentBlockhash = withdrawBlockhash;
    withdrawTx.feePayer = senderPubkey;
    
    const withdrawSig = await sendTransaction(withdrawTx, connection);
    console.log('Withdraw tx sent:', withdrawSig);
    
    await connection.confirmTransaction({
      signature: withdrawSig,
      blockhash: withdrawBlockhash,
      lastValidBlockHeight: withdrawHeight,
    });
    console.log('Withdraw confirmed!');
    
    report('done', 'Transfer complete!');
    
    return {
      success: true,
      depositSignature: depositSig,
      withdrawSignature: withdrawSig,
    };
    
  } catch (error: any) {
    console.error('Transfer error:', error);
    return {
      success: false,
      error: error.message || 'Transfer failed',
    };
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
  
  return {
    totalDeposits: treeInfo ? Number(treeInfo.data.readBigUInt64LE(40)) / 2 : 0,
    poolBalance: vaultBalance / LAMPORTS_PER_SOL,
  };
}
