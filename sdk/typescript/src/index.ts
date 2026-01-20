/**
 * Privacy-Zig TypeScript SDK
 * 
 * Provides helper functions for interacting with the privacy-pool program:
 * - Generate commitments for deposits
 * - Build transact instructions
 * - Generate ZK proofs using snarkjs
 * - Parse CommitmentData events
 */

import { Program, AnchorProvider, BN, Idl } from '@coral-xyz/anchor';
import { 
  PublicKey, 
  Keypair, 
  Connection,
  TransactionInstruction,
  SystemProgram,
} from '@solana/web3.js';
import { buildPoseidon } from 'circomlibjs';

// Re-export IDL
import idl from '../../programs/privacy-pool/idl/privacy_pool.json';
export { idl };

// Program ID
export const PROGRAM_ID = new PublicKey('Dz82AAVPumnUys5SQ8HMat5iD6xiBVMGC2xJiJdZkpbT');

// Constants from IDL
export const MERKLE_TREE_HEIGHT = 26;
export const ROOT_HISTORY_SIZE = 100;

// ============================================================================
// Types
// ============================================================================

export interface Utxo {
  amount: bigint;
  pubkey: bigint;
  blinding: bigint;
  mintAddress: PublicKey;
}

export interface Commitment {
  commitment: Uint8Array;
  nullifier: Uint8Array;
  secret: Uint8Array;
  amount: bigint;
}

export interface Proof {
  a: Uint8Array;
  b: Uint8Array;
  c: Uint8Array;
}

export interface TransactArgs {
  proof: Proof;
  root: Uint8Array;
  inputNullifier1: Uint8Array;
  inputNullifier2: Uint8Array;
  outputCommitment1: Uint8Array;
  outputCommitment2: Uint8Array;
  publicAmount: bigint;
  extDataHash: Uint8Array;
}

// ============================================================================
// Poseidon Hash (BN254)
// ============================================================================

let poseidonInstance: any = null;

export async function getPoseidon() {
  if (!poseidonInstance) {
    poseidonInstance = await buildPoseidon();
  }
  return poseidonInstance;
}

/**
 * Hash multiple elements using Poseidon
 */
export async function poseidonHash(inputs: bigint[]): Promise<Uint8Array> {
  const poseidon = await getPoseidon();
  const hash = poseidon(inputs);
  return poseidon.F.toObject(hash);
}

/**
 * Hash two elements using Poseidon
 */
export async function poseidonHash2(a: bigint, b: bigint): Promise<Uint8Array> {
  return poseidonHash([a, b]);
}

// ============================================================================
// Commitment Generation
// ============================================================================

/**
 * Generate a random 31-byte secret (fits in BN254 field)
 */
export function generateSecret(): Uint8Array {
  const secret = new Uint8Array(31);
  crypto.getRandomValues(secret);
  return secret;
}

/**
 * Generate a commitment for a deposit
 * 
 * commitment = poseidon(amount, pubkey, blinding, mintAddress)
 * nullifier = poseidon(commitment, pathIndex, signature)
 */
export async function generateCommitment(
  amount: bigint,
  pubkey: bigint,
  blinding: bigint,
  mintAddress: PublicKey
): Promise<Uint8Array> {
  const poseidon = await getPoseidon();
  
  // Convert mint address to field element
  const mintBytes = mintAddress.toBytes();
  const mintBigInt = BigInt('0x' + Buffer.from(mintBytes).toString('hex'));
  
  const hash = poseidon([amount, pubkey, blinding, mintBigInt]);
  const result = new Uint8Array(32);
  const hashBigInt = poseidon.F.toObject(hash);
  
  // Convert bigint to bytes (little-endian)
  for (let i = 0; i < 32; i++) {
    result[i] = Number((hashBigInt >> BigInt(i * 8)) & 0xFFn);
  }
  
  return result;
}

/**
 * Create a new UTXO for deposit
 */
export async function createUtxo(
  amount: bigint,
  recipientPubkey: bigint,
  mintAddress: PublicKey = SystemProgram.programId
): Promise<{
  utxo: Utxo;
  commitment: Uint8Array;
  blinding: bigint;
}> {
  // Generate random blinding factor
  const blindingBytes = generateSecret();
  const blinding = BigInt('0x' + Buffer.from(blindingBytes).toString('hex'));
  
  const utxo: Utxo = {
    amount,
    pubkey: recipientPubkey,
    blinding,
    mintAddress,
  };
  
  const commitment = await generateCommitment(
    amount,
    recipientPubkey,
    blinding,
    mintAddress
  );
  
  return { utxo, commitment, blinding };
}

// ============================================================================
// Merkle Tree
// ============================================================================

/**
 * Calculate zero hashes for empty tree levels
 */
export async function calculateZeroHashes(height: number): Promise<Uint8Array[]> {
  const poseidon = await getPoseidon();
  const zeros: Uint8Array[] = [new Uint8Array(32)]; // Level 0 = 0
  
  for (let i = 1; i <= height; i++) {
    const prevZero = zeros[i - 1];
    const prevBigInt = BigInt('0x' + Buffer.from(prevZero).toString('hex'));
    const hash = poseidon([prevBigInt, prevBigInt]);
    const result = new Uint8Array(32);
    const hashBigInt = poseidon.F.toObject(hash);
    
    for (let j = 0; j < 32; j++) {
      result[j] = Number((hashBigInt >> BigInt(j * 8)) & 0xFFn);
    }
    
    zeros.push(result);
  }
  
  return zeros;
}

/**
 * In-memory Merkle tree for off-chain computation
 */
export class MerkleTree {
  private leaves: Uint8Array[] = [];
  private height: number;
  private zeroHashes: Uint8Array[] = [];
  private poseidon: any;
  
  constructor(height: number = MERKLE_TREE_HEIGHT) {
    this.height = height;
  }
  
  async init() {
    this.poseidon = await getPoseidon();
    this.zeroHashes = await calculateZeroHashes(this.height);
  }
  
  /**
   * Insert a leaf and return its index
   */
  insert(leaf: Uint8Array): number {
    const index = this.leaves.length;
    this.leaves.push(leaf);
    return index;
  }
  
  /**
   * Get the current root
   */
  getRoot(): Uint8Array {
    if (this.leaves.length === 0) {
      return this.zeroHashes[this.height];
    }
    
    let currentLevel = [...this.leaves];
    
    for (let level = 0; level < this.height; level++) {
      const nextLevel: Uint8Array[] = [];
      
      for (let i = 0; i < currentLevel.length; i += 2) {
        const left = currentLevel[i];
        const right = i + 1 < currentLevel.length 
          ? currentLevel[i + 1] 
          : this.zeroHashes[level];
        
        const leftBigInt = BigInt('0x' + Buffer.from(left).toString('hex'));
        const rightBigInt = BigInt('0x' + Buffer.from(right).toString('hex'));
        
        const hash = this.poseidon([leftBigInt, rightBigInt]);
        const result = new Uint8Array(32);
        const hashBigInt = this.poseidon.F.toObject(hash);
        
        for (let j = 0; j < 32; j++) {
          result[j] = Number((hashBigInt >> BigInt(j * 8)) & 0xFFn);
        }
        
        nextLevel.push(result);
      }
      
      currentLevel = nextLevel.length > 0 ? nextLevel : [this.zeroHashes[level + 1]];
    }
    
    return currentLevel[0];
  }
  
  /**
   * Get Merkle proof for a leaf at given index
   */
  getProof(index: number): {
    pathElements: Uint8Array[];
    pathIndices: number[];
  } {
    const pathElements: Uint8Array[] = [];
    const pathIndices: number[] = [];
    
    let currentLevel = [...this.leaves];
    let currentIndex = index;
    
    for (let level = 0; level < this.height; level++) {
      const isRight = currentIndex % 2 === 1;
      pathIndices.push(isRight ? 1 : 0);
      
      const siblingIndex = isRight ? currentIndex - 1 : currentIndex + 1;
      const sibling = siblingIndex < currentLevel.length
        ? currentLevel[siblingIndex]
        : this.zeroHashes[level];
      
      pathElements.push(sibling);
      
      // Move to next level
      const nextLevel: Uint8Array[] = [];
      for (let i = 0; i < currentLevel.length; i += 2) {
        const left = currentLevel[i];
        const right = i + 1 < currentLevel.length 
          ? currentLevel[i + 1] 
          : this.zeroHashes[level];
        
        const leftBigInt = BigInt('0x' + Buffer.from(left).toString('hex'));
        const rightBigInt = BigInt('0x' + Buffer.from(right).toString('hex'));
        
        const hash = this.poseidon([leftBigInt, rightBigInt]);
        const result = new Uint8Array(32);
        const hashBigInt = this.poseidon.F.toObject(hash);
        
        for (let j = 0; j < 32; j++) {
          result[j] = Number((hashBigInt >> BigInt(j * 8)) & 0xFFn);
        }
        
        nextLevel.push(result);
      }
      
      currentLevel = nextLevel.length > 0 ? nextLevel : [this.zeroHashes[level + 1]];
      currentIndex = Math.floor(currentIndex / 2);
    }
    
    return { pathElements, pathIndices };
  }
}

// ============================================================================
// Program Client
// ============================================================================

export class PrivacyPoolClient {
  private program: Program;
  private provider: AnchorProvider;
  
  constructor(provider: AnchorProvider) {
    this.provider = provider;
    this.program = new Program(idl as Idl, provider);
  }
  
  /**
   * Initialize a new SOL privacy pool
   */
  async initialize(
    treeAccount: PublicKey,
    globalConfig: PublicKey,
    maxDepositAmount: bigint,
    feeRecipient: PublicKey
  ): Promise<string> {
    const tx = await this.program.methods
      .initialize(new BN(maxDepositAmount.toString()), feeRecipient)
      .accounts({
        treeAccount,
        globalConfig,
        authority: this.provider.wallet.publicKey,
      })
      .rpc();
    
    return tx;
  }
  
  /**
   * Execute a transact instruction (deposit/withdraw/transfer)
   */
  async transact(
    accounts: {
      treeAccount: PublicKey;
      nullifier1: PublicKey;
      nullifier2: PublicKey;
      globalConfig: PublicKey;
      poolVault: PublicKey;
      feeRecipient: PublicKey;
    },
    args: TransactArgs
  ): Promise<string> {
    const tx = await this.program.methods
      .transact(
        {
          a: Array.from(args.proof.a),
          b: Array.from(args.proof.b),
          c: Array.from(args.proof.c),
        },
        Array.from(args.root),
        Array.from(args.inputNullifier1),
        Array.from(args.inputNullifier2),
        Array.from(args.outputCommitment1),
        Array.from(args.outputCommitment2),
        new BN(args.publicAmount.toString()),
        Array.from(args.extDataHash)
      )
      .accounts({
        treeAccount: accounts.treeAccount,
        nullifier1: accounts.nullifier1,
        nullifier2: accounts.nullifier2,
        globalConfig: accounts.globalConfig,
        poolVault: accounts.poolVault,
        user: this.provider.wallet.publicKey,
        feeRecipient: accounts.feeRecipient,
      })
      .rpc();
    
    return tx;
  }
  
  /**
   * Fetch tree account data
   */
  async fetchTreeAccount(address: PublicKey) {
    return await this.program.account.treeAccount.fetch(address);
  }
  
  /**
   * Fetch global config
   */
  async fetchGlobalConfig(address: PublicKey) {
    return await this.program.account.globalConfig.fetch(address);
  }
  
  /**
   * Parse CommitmentData events from transaction logs
   */
  parseCommitmentEvents(logs: string[]): Array<{
    index: bigint;
    commitment: Uint8Array;
  }> {
    const events: Array<{ index: bigint; commitment: Uint8Array }> = [];
    
    // Event discriminator for CommitmentData
    const eventDiscriminator = [13, 110, 215, 127, 244, 62, 234, 34];
    
    for (const log of logs) {
      if (log.startsWith('Program data: ')) {
        const data = Buffer.from(log.slice(14), 'base64');
        
        // Check discriminator
        let matches = true;
        for (let i = 0; i < 8; i++) {
          if (data[i] !== eventDiscriminator[i]) {
            matches = false;
            break;
          }
        }
        
        if (matches && data.length >= 48) {
          const index = data.readBigUInt64LE(8);
          const commitment = new Uint8Array(data.slice(16, 48));
          events.push({ index, commitment });
        }
      }
    }
    
    return events;
  }
}

// ============================================================================
// Exports
// ============================================================================

export default {
  PROGRAM_ID,
  MERKLE_TREE_HEIGHT,
  ROOT_HISTORY_SIZE,
  getPoseidon,
  poseidonHash,
  poseidonHash2,
  generateSecret,
  generateCommitment,
  createUtxo,
  calculateZeroHashes,
  MerkleTree,
  PrivacyPoolClient,
};
