/**
 * Privacy Pool Client Library
 * 
 * Handles commitment generation, Merkle tree management,
 * and interaction with the on-chain program.
 */

import { Connection, PublicKey, SystemProgram } from '@solana/web3.js';
import { buildPoseidon } from 'circomlibjs';

// Program ID (update after deployment)
export const PROGRAM_ID = new PublicKey('PrivZig111111111111111111111111111111111111');

// Constants
export const MERKLE_TREE_HEIGHT = 26;

// ============================================================================
// Types
// ============================================================================

export interface DepositNote {
  secret: string;        // Hex encoded secret
  nullifier: string;     // Hex encoded nullifier
  commitment: string;    // Hex encoded commitment
  amount: string;        // Amount in lamports
  leafIndex: number;     // Position in Merkle tree
  timestamp: number;     // When deposited
}

export interface MerkleProof {
  pathElements: string[];
  pathIndices: number[];
  root: string;
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

function bigintToBytes32(n: bigint): Uint8Array {
  const result = new Uint8Array(32);
  for (let i = 0; i < 32; i++) {
    result[i] = Number((n >> BigInt(i * 8)) & 0xFFn);
  }
  return result;
}

function bytes32ToBigint(bytes: Uint8Array): bigint {
  let result = 0n;
  for (let i = 0; i < 32; i++) {
    result |= BigInt(bytes[i]) << BigInt(i * 8);
  }
  return result;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
  }
  return bytes;
}

// ============================================================================
// Commitment Generation
// ============================================================================

/**
 * Generate a random 31-byte value (fits in BN254 field)
 */
function generateRandom31Bytes(): Uint8Array {
  const bytes = new Uint8Array(31);
  crypto.getRandomValues(bytes);
  return bytes;
}

/**
 * Generate a deposit note
 * 
 * commitment = poseidon(amount, pubkey, blinding, mintAddress)
 * For simplicity, we use: commitment = poseidon(secret, nullifier, amount)
 */
export async function generateDepositNote(
  amountLamports: bigint
): Promise<DepositNote> {
  const poseidon = await getPoseidon();
  
  // Generate random secret and nullifier
  const secretBytes = generateRandom31Bytes();
  const nullifierBytes = generateRandom31Bytes();
  
  const secret = bytes32ToBigint(new Uint8Array([...secretBytes, 0]));
  const nullifier = bytes32ToBigint(new Uint8Array([...nullifierBytes, 0]));
  
  // Compute commitment = poseidon(secret, nullifier, amount)
  const hash = poseidon([secret, nullifier, amountLamports]);
  const commitmentBigInt = poseidon.F.toObject(hash);
  const commitment = bigintToBytes32(commitmentBigInt);
  
  return {
    secret: bytesToHex(secretBytes),
    nullifier: bytesToHex(nullifierBytes),
    commitment: bytesToHex(commitment),
    amount: amountLamports.toString(),
    leafIndex: -1, // Set after deposit
    timestamp: Date.now(),
  };
}

/**
 * Parse a deposit note from string (for withdrawal)
 */
export function parseDepositNote(noteString: string): DepositNote {
  try {
    return JSON.parse(atob(noteString));
  } catch {
    throw new Error('Invalid deposit note format');
  }
}

/**
 * Serialize a deposit note to string (for saving)
 */
export function serializeDepositNote(note: DepositNote): string {
  return btoa(JSON.stringify(note));
}

// ============================================================================
// Merkle Tree (Client-side)
// ============================================================================

export class ClientMerkleTree {
  private leaves: Uint8Array[] = [];
  private height: number;
  private zeroHashes: Uint8Array[] = [];
  private poseidon: any;
  private initialized = false;

  constructor(height: number = MERKLE_TREE_HEIGHT) {
    this.height = height;
  }

  async init() {
    if (this.initialized) return;
    
    this.poseidon = await getPoseidon();
    
    // Calculate zero hashes
    this.zeroHashes = [new Uint8Array(32)];
    for (let i = 1; i <= this.height; i++) {
      const prev = this.zeroHashes[i - 1];
      const prevBigInt = bytes32ToBigint(prev);
      const hash = this.poseidon([prevBigInt, prevBigInt]);
      const hashBigInt = this.poseidon.F.toObject(hash);
      this.zeroHashes.push(bigintToBytes32(hashBigInt));
    }
    
    this.initialized = true;
  }

  insert(commitment: Uint8Array): number {
    const index = this.leaves.length;
    this.leaves.push(commitment);
    return index;
  }

  insertHex(commitmentHex: string): number {
    return this.insert(hexToBytes(commitmentHex));
  }

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

        const leftBigInt = bytes32ToBigint(left);
        const rightBigInt = bytes32ToBigint(right);

        const hash = this.poseidon([leftBigInt, rightBigInt]);
        const hashBigInt = this.poseidon.F.toObject(hash);
        nextLevel.push(bigintToBytes32(hashBigInt));
      }

      currentLevel = nextLevel.length > 0 ? nextLevel : [this.zeroHashes[level + 1]];
    }

    return currentLevel[0];
  }

  getRootHex(): string {
    return bytesToHex(this.getRoot());
  }

  getProof(index: number): MerkleProof {
    const pathElements: string[] = [];
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

      pathElements.push(bytesToHex(sibling));

      // Move to next level
      const nextLevel: Uint8Array[] = [];
      for (let i = 0; i < currentLevel.length; i += 2) {
        const left = currentLevel[i];
        const right = i + 1 < currentLevel.length
          ? currentLevel[i + 1]
          : this.zeroHashes[level];

        const leftBigInt = bytes32ToBigint(left);
        const rightBigInt = bytes32ToBigint(right);

        const hash = this.poseidon([leftBigInt, rightBigInt]);
        const hashBigInt = this.poseidon.F.toObject(hash);
        nextLevel.push(bigintToBytes32(hashBigInt));
      }

      currentLevel = nextLevel.length > 0 ? nextLevel : [this.zeroHashes[level + 1]];
      currentIndex = Math.floor(currentIndex / 2);
    }

    return {
      pathElements,
      pathIndices,
      root: this.getRootHex(),
    };
  }

  get leafCount(): number {
    return this.leaves.length;
  }
}

// ============================================================================
// On-chain Event Parsing
// ============================================================================

interface CommitmentEvent {
  index: number;
  commitment: string;
}

/**
 * Parse CommitmentData events from transaction logs
 */
export function parseCommitmentEvents(logs: string[]): CommitmentEvent[] {
  const events: CommitmentEvent[] = [];
  
  // Event discriminator for CommitmentData
  const eventDiscriminator = [13, 110, 215, 127, 244, 62, 234, 34];

  for (const log of logs) {
    if (log.startsWith('Program data: ')) {
      try {
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
          const index = Number(data.readBigUInt64LE(8));
          const commitment = bytesToHex(new Uint8Array(data.slice(16, 48)));
          events.push({ index, commitment });
        }
      } catch (e) {
        // Skip invalid logs
      }
    }
  }

  return events;
}

/**
 * Rebuild Merkle tree from on-chain events
 */
export async function rebuildTreeFromChain(
  connection: Connection,
  programId: PublicKey = PROGRAM_ID
): Promise<ClientMerkleTree> {
  const tree = new ClientMerkleTree();
  await tree.init();

  // Get all signatures for the program
  const signatures = await connection.getSignaturesForAddress(programId, { limit: 1000 });

  // Process in chronological order (oldest first)
  for (const sig of signatures.reverse()) {
    try {
      const tx = await connection.getTransaction(sig.signature, {
        maxSupportedTransactionVersion: 0,
      });

      if (tx?.meta?.logMessages) {
        const events = parseCommitmentEvents(tx.meta.logMessages);
        for (const event of events) {
          tree.insertHex(event.commitment);
        }
      }
    } catch (e) {
      console.warn('Failed to parse tx:', sig.signature);
    }
  }

  return tree;
}

// ============================================================================
// Local Storage
// ============================================================================

const STORAGE_KEY = 'privacy-zig-notes';

export function saveNoteToStorage(note: DepositNote): void {
  const notes = getNotesFromStorage();
  notes.push(note);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(notes));
}

export function getNotesFromStorage(): DepositNote[] {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored ? JSON.parse(stored) : [];
  } catch {
    return [];
  }
}

export function removeNoteFromStorage(commitment: string): void {
  const notes = getNotesFromStorage();
  const filtered = notes.filter(n => n.commitment !== commitment);
  localStorage.setItem(STORAGE_KEY, JSON.stringify(filtered));
}
