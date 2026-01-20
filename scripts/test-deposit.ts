import {
  Connection,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
  ComputeBudgetProgram,
  Keypair,
  sendAndConfirmTransaction,
} from '@solana/web3.js';
import * as snarkjs from 'snarkjs';
import { utils as ffUtils } from 'ffjavascript';
import { buildPoseidon } from 'circomlibjs';
import BN from 'bn.js';
import * as fs from 'fs';
import * as path from 'path';

const PROGRAM_ID = new PublicKey('Dz82AAVPumnUys5SQ8HMat5iD6xiBVMGC2xJiJdZkpbT');
const MERKLE_TREE_HEIGHT = 26;
const FIELD_SIZE = new BN('21888242871839275222246405745257275088548364400416034343698204186575808495617');
const BN254_FIELD_MODULUS = BigInt('21888242871839275222246405745257275088696311157297823662689037894645226208583');

const TRANSACT_DISCRIMINATOR = new Uint8Array([217, 149, 130, 143, 221, 52, 252, 119]);

const POOL_CONFIG = {
  treeAccount: new PublicKey('2h8oJdtfe9AE8r3Dmp49iBruUMfQQMmo6r63q79vxUN1'),
  globalConfig: new PublicKey('9qQELDcp6Z48tLpsDs6RtSQbYx5GpquxB4staTKQz15i'),
  feeRecipient: new PublicKey('FM7WTd5Hr7ppp6vu3M4uAspF4DoRjrYPPFvAmqB7H95D'),
};

let poseidonInstance: any = null;

async function initPoseidon() {
  poseidonInstance = await buildPoseidon();
}

function poseidonHash(inputs: bigint[]): bigint {
  const hash = poseidonInstance(inputs);
  return poseidonInstance.F.toObject(hash);
}

function generateRandom31Bytes(): Uint8Array {
  const bytes = new Uint8Array(31);
  for (let i = 0; i < 31; i++) {
    bytes[i] = Math.floor(Math.random() * 256);
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
}

function negateG1Point(x: bigint, y: bigint): { x: bigint; y: bigint } {
  return { x, y: (BN254_FIELD_MODULUS - y) % BN254_FIELD_MODULUS };
}

async function main() {
  await initPoseidon();
  
  const connection = new Connection('https://api.testnet.solana.com', 'confirmed');
  
  // Load keypair
  const keypairPath = path.join(process.env.HOME!, '.config/solana/id.json');
  const secretKey = JSON.parse(fs.readFileSync(keypairPath, 'utf8'));
  const payer = Keypair.fromSecretKey(new Uint8Array(secretKey));
  
  console.log('Payer:', payer.publicKey.toBase58());
  
  const balance = await connection.getBalance(payer.publicKey);
  console.log('Balance:', balance / 1e9, 'SOL');
  
  // Get current state
  const treeInfo = await connection.getAccountInfo(POOL_CONFIG.treeAccount);
  if (!treeInfo) throw new Error('Tree account not found');
  
  const leafIndex = Number(treeInfo.data.readBigUInt64LE(40));
  console.log('Current leaf index:', leafIndex);
  
  // Build empty tree to get root for deposit
  const tree = new MerkleTree();
  const emptyRoot = tree.zeros[MERKLE_TREE_HEIGHT];
  console.log('Empty root:', emptyRoot.toString());
  
  // Generate UTXO keypair
  const utxoKeypair = generateKeypair();
  const solMintAddress = 1n;
  const amountLamports = 10000000; // 0.01 SOL
  
  // Dummy inputs
  const dummyBlinding1 = generateBlinding();
  const dummyBlinding2 = generateBlinding();
  const dummyCommitment1 = poseidonHash([0n, utxoKeypair.pubkey, dummyBlinding1, solMintAddress]);
  const dummyCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, dummyBlinding2, solMintAddress]);
  const dummySig1 = poseidonHash([utxoKeypair.privkey, dummyCommitment1, 0n]);
  const dummySig2 = poseidonHash([utxoKeypair.privkey, dummyCommitment2, 0n]);
  const inputNullifier1 = poseidonHash([dummyCommitment1, 0n, dummySig1]);
  const inputNullifier2 = poseidonHash([dummyCommitment2, 0n, dummySig2]);
  
  // Output commitments
  const outBlinding1 = generateBlinding();
  const outBlinding2 = generateBlinding();
  const outputCommitment1 = poseidonHash([BigInt(amountLamports), utxoKeypair.pubkey, outBlinding1, solMintAddress]);
  const outputCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, outBlinding2, solMintAddress]);
  
  const depositPublicAmount = new BN(amountLamports).add(FIELD_SIZE).mod(FIELD_SIZE);
  const senderNum = BigInt('0x' + payer.publicKey.toBuffer().toString('hex').slice(0, 16));
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
  
  console.log('Generating proof...');
  
  const wasmPath = path.join(__dirname, '../app/public/circuits/transaction2.wasm');
  const zkeyPath = path.join(__dirname, '../app/public/circuits/transaction2.zkey');
  
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    ffUtils.stringifyBigInts(depositInput),
    wasmPath,
    zkeyPath
  );
  
  console.log('Proof generated!');
  console.log('Public signals:', publicSignals);
  
  // Serialize proof
  const piA_x = BigInt(proof.pi_a[0]);
  const piA_y = BigInt(proof.pi_a[1]);
  const negA = negateG1Point(piA_x, piA_y);
  
  const proofA = Buffer.concat([
    Buffer.from(ffUtils.leInt2Buff(negA.x, 32)).reverse(),
    Buffer.from(ffUtils.leInt2Buff(negA.y, 32)).reverse(),
  ]);
  
  const proofB = Buffer.concat([
    Buffer.from(ffUtils.leInt2Buff(BigInt(proof.pi_b[0][1]), 32)).reverse(),
    Buffer.from(ffUtils.leInt2Buff(BigInt(proof.pi_b[0][0]), 32)).reverse(),
    Buffer.from(ffUtils.leInt2Buff(BigInt(proof.pi_b[1][1]), 32)).reverse(),
    Buffer.from(ffUtils.leInt2Buff(BigInt(proof.pi_b[1][0]), 32)).reverse(),
  ]);
  
  const proofC = Buffer.concat([
    Buffer.from(ffUtils.leInt2Buff(BigInt(proof.pi_c[0]), 32)).reverse(),
    Buffer.from(ffUtils.leInt2Buff(BigInt(proof.pi_c[1]), 32)).reverse(),
  ]);
  
  const proofBuffer = Buffer.concat([proofA, proofB, proofC]);
  
  // Serialize public signals
  const publicInputs = publicSignals.map((sig: string) => 
    Buffer.from(ffUtils.leInt2Buff(ffUtils.unstringifyBigInts(sig), 32)).reverse()
  );
  
  // Build instruction data
  const depositData = Buffer.alloc(8 + 256 + 32 * 5 + 8 + 32);
  let offset = 0;
  Buffer.from(TRANSACT_DISCRIMINATOR).copy(depositData, offset); offset += 8;
  proofBuffer.copy(depositData, offset); offset += 256;
  publicInputs[0].copy(depositData, offset); offset += 32; // root
  publicInputs[3].copy(depositData, offset); offset += 32; // nullifier1
  publicInputs[4].copy(depositData, offset); offset += 32; // nullifier2
  publicInputs[5].copy(depositData, offset); offset += 32; // commitment1
  publicInputs[6].copy(depositData, offset); offset += 32; // commitment2
  depositData.writeBigInt64LE(BigInt(amountLamports), offset); offset += 8;
  publicInputs[2].copy(depositData, offset); // extDataHash
  
  console.log('Instruction data length:', depositData.length);
  
  // Derive PDAs
  const [null1PDA] = PublicKey.findProgramAddressSync(
    [Buffer.from('nullifier'), publicInputs[3]],
    PROGRAM_ID
  );
  const [null2PDA] = PublicKey.findProgramAddressSync(
    [Buffer.from('nullifier'), publicInputs[4]],
    PROGRAM_ID
  );
  const [poolVault] = PublicKey.findProgramAddressSync(
    [Buffer.from('pool_vault')],
    PROGRAM_ID
  );
  
  console.log('Nullifier1 PDA:', null1PDA.toBase58());
  console.log('Nullifier2 PDA:', null2PDA.toBase58());
  console.log('Pool vault:', poolVault.toBase58());
  
  const depositIx = new TransactionInstruction({
    keys: [
      { pubkey: POOL_CONFIG.treeAccount, isSigner: false, isWritable: true },
      { pubkey: null1PDA, isSigner: false, isWritable: true },
      { pubkey: null2PDA, isSigner: false, isWritable: true },
      { pubkey: POOL_CONFIG.globalConfig, isSigner: false, isWritable: false },
      { pubkey: poolVault, isSigner: false, isWritable: true },
      { pubkey: payer.publicKey, isSigner: true, isWritable: true },
      { pubkey: POOL_CONFIG.feeRecipient, isSigner: false, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    programId: PROGRAM_ID,
    data: depositData,
  });
  
  // First simulate
  console.log('\nSimulating transaction...');
  const tx = new Transaction()
    .add(ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }))
    .add(depositIx);
  
  tx.recentBlockhash = (await connection.getLatestBlockhash()).blockhash;
  tx.feePayer = payer.publicKey;
  
  try {
    const simResult = await connection.simulateTransaction(tx);
    console.log('Simulation result:', JSON.stringify(simResult.value, null, 2));
    
    if (simResult.value.err) {
      console.log('Simulation error:', simResult.value.err);
      if (simResult.value.logs) {
        console.log('\nLogs:');
        simResult.value.logs.forEach((log: string) => console.log('  ', log));
      }
    } else {
      console.log('Simulation succeeded! Sending transaction...');
      const sig = await sendAndConfirmTransaction(connection, tx, [payer]);
      console.log('Transaction confirmed:', sig);
    }
  } catch (e: any) {
    console.error('Error:', e.message);
    if (e.logs) {
      console.log('\nLogs:');
      e.logs.forEach((log: string) => console.log('  ', log));
    }
  }
}

main().catch(console.error);
