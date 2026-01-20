/**
 * Initialize Privacy Pool on Testnet
 * 
 * Creates TreeAccount and GlobalConfig for the privacy pool.
 * Run this once after deploying the program.
 * 
 * Usage: npx tsx initialize.ts
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

// Program ID (deployed on testnet)
const PROGRAM_ID = new PublicKey('Dz82AAVPumnUys5SQ8HMat5iD6xiBVMGC2xJiJdZkpbT');

// Discriminator for initialize instruction (from IDL)
const INITIALIZE_DISCRIMINATOR = Buffer.from([175, 175, 109, 31, 13, 152, 155, 237]);

async function main() {
  console.log('=== Privacy Pool Initialization ===\n');
  
  // Load keypair from default location
  const keypairPath = process.env.HOME + '/.config/solana/id.json';
  const keypairData = JSON.parse(fs.readFileSync(keypairPath, 'utf-8'));
  const payer = Keypair.fromSecretKey(Uint8Array.from(keypairData));
  
  console.log('Payer:', payer.publicKey.toBase58());
  
  // Connect to testnet
  const connection = new Connection('https://api.testnet.solana.com', 'confirmed');
  const balance = await connection.getBalance(payer.publicKey);
  console.log('Balance:', balance / LAMPORTS_PER_SOL, 'SOL\n');
  
  // Generate new keypairs for accounts
  const treeAccount = Keypair.generate();
  const globalConfig = Keypair.generate();
  
  console.log('Tree Account:', treeAccount.publicKey.toBase58());
  console.log('Global Config:', globalConfig.publicKey.toBase58());
  
  // Build initialize instruction data
  // Args: max_deposit_amount (u64), fee_recipient (pubkey)
  const maxDepositAmount = BigInt(100 * LAMPORTS_PER_SOL); // 100 SOL max
  const feeRecipient = payer.publicKey;
  
  const data = Buffer.alloc(8 + 8 + 32);
  INITIALIZE_DISCRIMINATOR.copy(data, 0);
  data.writeBigUInt64LE(maxDepositAmount, 8);
  feeRecipient.toBuffer().copy(data, 16);
  
  // Build instruction
  const initializeIx = new TransactionInstruction({
    keys: [
      { pubkey: treeAccount.publicKey, isSigner: true, isWritable: true },
      { pubkey: globalConfig.publicKey, isSigner: true, isWritable: true },
      { pubkey: payer.publicKey, isSigner: true, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    programId: PROGRAM_ID,
    data,
  });
  
  // Add compute budget (init creates large accounts)
  const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({
    units: 400000,
  });
  
  const transaction = new Transaction()
    .add(computeBudgetIx)
    .add(initializeIx);
  
  console.log('\nSending transaction...');
  
  try {
    const signature = await sendAndConfirmTransaction(
      connection,
      transaction,
      [payer, treeAccount, globalConfig],
      { commitment: 'confirmed' }
    );
    
    console.log('\n✅ Initialization successful!');
    console.log('Signature:', signature);
    console.log('Explorer:', `https://explorer.solana.com/tx/${signature}?cluster=testnet`);
    
    // Save config for other scripts
    const config = {
      programId: PROGRAM_ID.toBase58(),
      treeAccount: treeAccount.publicKey.toBase58(),
      globalConfig: globalConfig.publicKey.toBase58(),
      feeRecipient: feeRecipient.toBase58(),
      network: 'testnet',
    };
    
    fs.writeFileSync('deployed-config.json', JSON.stringify(config, null, 2));
    console.log('\n📁 Config saved to deployed-config.json');
    
    // Verify accounts
    console.log('\nVerifying accounts...');
    const treeInfo = await connection.getAccountInfo(treeAccount.publicKey);
    const configInfo = await connection.getAccountInfo(globalConfig.publicKey);
    
    if (treeInfo && configInfo) {
      console.log('  Tree Account: ✅ size:', treeInfo.data.length, 'bytes');
      console.log('  Global Config: ✅ size:', configInfo.data.length, 'bytes');
    }
    
  } catch (error: any) {
    console.error('\n❌ Initialization failed:', error.message);
    if (error.logs) {
      console.log('\nProgram logs:');
      error.logs.forEach((log: string) => console.log('  ', log));
    }
  }
}

main().catch(console.error);
