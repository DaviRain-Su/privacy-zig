/**
 * Debug script to output witness inputs for comparison with Rust
 */

import {
  Connection,
  PublicKey,
} from '@solana/web3.js';
import * as fs from 'fs';
import * as path from 'path';
import { buildPoseidon } from 'circomlibjs';
// @ts-ignore
import { utils } from 'ffjavascript';
import * as crypto from 'crypto';

const PROGRAM_ID = new PublicKey('Dz82AAVPumnUys5SQ8HMat5iD6xiBVMGC2xJiJdZkpbT');
const MERKLE_TREE_HEIGHT = 26;
const FIELD_SIZE = BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617');
const TRANSACT_DISCRIMINATOR = Buffer.from([217, 149, 130, 143, 221, 52, 252, 119]);

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

class MerkleTree {
  height: number;
  zeros: bigint[];
  leaves: bigint[] = [];
  layers: bigint[][] = [];
  
  constructor(height: number) {
    this.height = height;
    this.zeros = this.computeZeroHashes();
  }
  
  computeZeroHashes(): bigint[] {
    const zeros: bigint[] = [0n];
    for (let i = 1; i <= this.height; i++) {
      zeros.push(poseidonHash([zeros[i - 1], zeros[i - 1]]));
    }
    return zeros;
  }
  
  insert(leaf: bigint) {
    this.leaves.push(leaf);
    this.rebuildTree();
  }
  
  rebuildTree() {
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
      if (siblingIndex < currentLayer.length) {
        pathElements.push(currentLayer[siblingIndex]);
      } else {
        pathElements.push(this.zeros[level]);
      }
      
      currentIndex = Math.floor(currentIndex / 2);
    }
    
    return { pathElements, pathIndices };
  }
}

async function fetchCommitmentsFromChain(connection: Connection): Promise<bigint[]> {
  const treeAccount = new PublicKey('2h8oJdtfe9AE8r3Dmp49iBruUMfQQMmo6r63q79vxUN1');
  const signatures = await connection.getSignaturesForAddress(treeAccount, { limit: 1000 });
  
  const commitments: bigint[] = [];
  
  for (const sigInfo of signatures.reverse()) {
    try {
      const tx = await connection.getTransaction(sigInfo.signature, {
        commitment: 'confirmed',
        maxSupportedTransactionVersion: 0,
      });
      
      if (!tx || !tx.meta || tx.meta.err) continue;
      
      const message = tx.transaction.message;
      const instructions = message.compiledInstructions || [];
      
      for (const ix of instructions) {
        const progIdIndex = ix.programIdIndex;
        const accountKeys = message.staticAccountKeys || message.accountKeys;
        
        if (accountKeys[progIdIndex].equals(PROGRAM_ID)) {
          const data = Buffer.from(ix.data);
          
          if (data.length >= 400 && data.slice(0, 8).equals(TRANSACT_DISCRIMINATOR)) {
            const c1 = BigInt('0x' + data.slice(360, 392).toString('hex'));
            const c2 = BigInt('0x' + data.slice(392, 424).toString('hex'));
            commitments.push(c1, c2);
          }
        }
      }
    } catch (e) {}
  }
  
  return commitments;
}

function generateBlinding(): bigint {
  const bytes = crypto.randomBytes(31);
  return BigInt('0x' + bytes.toString('hex'));
}

async function main() {
  // Note data from Rust CLI
  const note = {
    amount: 2000000,
    privkey: "226953907348593237456897810214995176770350174308054297189806996463229495108",
    pubkey: "18898625292415417708955911259859675264038140818688384915448439877831452457385",
    blinding: "332833320559612913185230762932921145217332282596639601314779977996463827013",
    commitment: "12305925769595727949963018365032131676544897512230041699170469209058476100683",
    leaf_index: 40,
  };
  
  const recipient = new PublicKey('8XqveGWGyyth5cnyRKZxbCZdqNfVAxsFcqWqLwGmCMjR');
  
  await getPoseidon();
  
  const connection = new Connection('https://api.testnet.solana.com', 'confirmed');
  
  // Fetch commitments and build tree
  console.log('Fetching commitments...');
  const commitments = await fetchCommitmentsFromChain(connection);
  console.log('Total commitments:', commitments.length);
  
  const tree = new MerkleTree(MERKLE_TREE_HEIGHT);
  for (const c of commitments) {
    tree.insert(c);
  }
  
  const root = tree.getRoot();
  console.log('\n=== Tree Info ===');
  console.log('Root:', root.toString());
  console.log('Leaves:', tree.leaves.length);
  
  // Find our commitment
  const ourCommitment = BigInt(note.commitment);
  const leafIndex = tree.leaves.findIndex(l => l === ourCommitment);
  console.log('Our commitment index:', leafIndex);
  console.log('Note leaf_index:', note.leaf_index);
  
  if (leafIndex === -1) {
    console.error('Commitment not found!');
    return;
  }
  
  // Get Merkle path
  const { pathElements, pathIndices } = tree.getPath(leafIndex);
  
  // Compute values for withdraw
  const privkey = BigInt(note.privkey);
  const pubkey = BigInt(note.pubkey);
  const blinding = BigInt(note.blinding);
  const amount = BigInt(note.amount);
  const solMintAddress = 1n;
  
  // Signature and nullifier for input 1
  const signature1 = poseidonHash([privkey, ourCommitment, BigInt(leafIndex)]);
  const nullifier1 = poseidonHash([ourCommitment, BigInt(leafIndex), signature1]);
  
  // Dummy input 2
  const dummyBlinding = generateBlinding();
  const dummyCommitment = poseidonHash([0n, pubkey, dummyBlinding, solMintAddress]);
  const dummySig = poseidonHash([privkey, dummyCommitment, 0n]);
  const nullifier2 = poseidonHash([dummyCommitment, 0n, dummySig]);
  
  // Output commitments (both zero for withdrawal)
  const outBlinding1 = generateBlinding();
  const outBlinding2 = generateBlinding();
  const outputCommitment1 = poseidonHash([0n, pubkey, outBlinding1, solMintAddress]);
  const outputCommitment2 = poseidonHash([0n, pubkey, outBlinding2, solMintAddress]);
  
  // Public amount (negative)
  const publicAmount = (FIELD_SIZE - amount) % FIELD_SIZE;
  
  // ExtData hash
  const recipientBytes = recipient.toBuffer();
  const recipientNum = BigInt('0x' + recipientBytes.slice(0, 8).toString('hex'));
  const extDataHash = poseidonHash([recipientNum, amount]);
  
  console.log('\n=== Witness Inputs (for Rust comparison) ===');
  console.log('root:', root.toString());
  console.log('publicAmount:', publicAmount.toString());
  console.log('extDataHash:', extDataHash.toString());
  console.log('mintAddress: 1');
  console.log('inputNullifier[0]:', nullifier1.toString());
  console.log('inputNullifier[1]:', nullifier2.toString());
  console.log('inAmount[0]:', amount.toString());
  console.log('inAmount[1]: 0');
  console.log('inPrivateKey[0]:', privkey.toString());
  console.log('inPrivateKey[1]:', privkey.toString());
  console.log('inBlinding[0]:', blinding.toString());
  console.log('inBlinding[1]:', dummyBlinding.toString());
  console.log('inPathIndices[0]:', leafIndex);
  console.log('inPathIndices[1]: 0');
  console.log('inPathElements[0][0..3]:', pathElements.slice(0, 3).map(e => e.toString()).join(', '));
  console.log('outputCommitment[0]:', outputCommitment1.toString());
  console.log('outputCommitment[1]:', outputCommitment2.toString());
  console.log('outAmount[0]: 0');
  console.log('outAmount[1]: 0');
  console.log('outPubkey[0]:', pubkey.toString());
  console.log('outPubkey[1]:', pubkey.toString());
  console.log('outBlinding[0]:', outBlinding1.toString());
  console.log('outBlinding[1]:', outBlinding2.toString());
  
  // Verify commitment calculation
  const verifyCommitment = poseidonHash([amount, pubkey, blinding, solMintAddress]);
  console.log('\n=== Verification ===');
  console.log('Computed commitment:', verifyCommitment.toString());
  console.log('Note commitment:', note.commitment);
  console.log('Match:', verifyCommitment.toString() === note.commitment);
}

main().catch(console.error);
