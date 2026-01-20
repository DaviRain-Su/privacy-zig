/**
 * Initialize Privacy Pool on Testnet
 * 
 * This script calls the initialize instruction which will create
 * the TreeAccount and GlobalConfig accounts using init constraint.
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
  console.log('Balance:', balance / 1e9, 'SOL\n');
  
  // Generate new keypairs for accounts (needed as signers for init)
  const treeAccount = Keypair.generate();
  const globalConfig = Keypair.generate();
  
  console.log('Tree Account:', treeAccount.publicKey.toBase58());
  console.log('Global Config:', globalConfig.publicKey.toBase58());
  
  // Build initialize instruction data
  // Args: max_deposit_amount (u64), fee_recipient (pubkey)
  const maxDepositAmount = BigInt(100 * 1e9); // 100 SOL max per deposit
  const feeRecipient = payer.publicKey;
  
  const data = Buffer.alloc(8 + 8 + 32);
  INITIALIZE_DISCRIMINATOR.copy(data, 0);
  data.writeBigUInt64LE(maxDepositAmount, 8);
  feeRecipient.toBuffer().copy(data, 16);
  
  // Build initialize instruction
  // Accounts order (from IDL):
  // 1. tree_account (writable, signer - for init)
  // 2. global_config (writable, signer - for init)
  // 3. authority (signer, writable - payer for init)
  // 4. system_program
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
  
  // Add compute budget for safety (init creates large accounts)
  const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({
    units: 400000,
  });
  
  // Build transaction
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
    
    // Save config
    const config = {
      programId: PROGRAM_ID.toBase58(),
      treeAccount: treeAccount.publicKey.toBase58(),
      globalConfig: globalConfig.publicKey.toBase58(),
      feeRecipient: feeRecipient.toBase58(),
      network: 'testnet',
    };
    
    fs.writeFileSync('deployed-config.json', JSON.stringify(config, null, 2));
    console.log('\nConfig saved to deployed-config.json');
    
    // Verify accounts created
    console.log('\nVerifying accounts...');
    const treeInfo = await connection.getAccountInfo(treeAccount.publicKey);
    const configInfo = await connection.getAccountInfo(globalConfig.publicKey);
    
    if (treeInfo && configInfo) {
      console.log('  Tree Account: ✅ exists, size:', treeInfo.data.length);
      console.log('  Global Config: ✅ exists, size:', configInfo.data.length);
      console.log('  Tree discriminator:', Buffer.from(treeInfo.data.slice(0, 8)).toString('hex'));
      console.log('  Config discriminator:', Buffer.from(configInfo.data.slice(0, 8)).toString('hex'));
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
