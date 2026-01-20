/**
 * Initialize Privacy Pool on Testnet
 * 
 * This script:
 * 1. Creates TreeAccount with correct size and discriminator
 * 2. Creates GlobalConfig with correct size and discriminator
 * 3. Calls initialize instruction
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

// Account sizes (calculated from Zig structs + 8 bytes discriminator)
// TreeAccount: 32 + 8 + 8 + 1 + 8 + 1 + 1 + 5 + 3200 + 832 = 4096 + 8 discriminator = 4104
const TREE_ACCOUNT_SIZE = 4104;

// GlobalConfig: 32 + 32 + 2 + 2 + 2 + 1 + 1 = 72 + 8 discriminator = 80
const GLOBAL_CONFIG_SIZE = 80;

// Discriminators (from IDL)
const INITIALIZE_DISCRIMINATOR = Buffer.from([175, 175, 109, 31, 13, 152, 155, 237]);
const TREE_ACCOUNT_DISCRIMINATOR = Buffer.from([214, 38, 107, 35, 76, 133, 73, 49]);
const GLOBAL_CONFIG_DISCRIMINATOR = Buffer.from([149, 8, 156, 202, 160, 252, 176, 217]);

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
  
  // Generate new keypairs for accounts
  const treeAccount = Keypair.generate();
  const globalConfig = Keypair.generate();
  
  console.log('Tree Account:', treeAccount.publicKey.toBase58());
  console.log('Global Config:', globalConfig.publicKey.toBase58());
  
  // Calculate rent
  const treeRent = await connection.getMinimumBalanceForRentExemption(TREE_ACCOUNT_SIZE);
  const configRent = await connection.getMinimumBalanceForRentExemption(GLOBAL_CONFIG_SIZE);
  
  console.log('\nRent required:');
  console.log('  Tree Account:', treeRent / 1e9, 'SOL');
  console.log('  Global Config:', configRent / 1e9, 'SOL');
  console.log('  Total:', (treeRent + configRent) / 1e9, 'SOL');
  
  // Step 1: Create accounts with discriminators pre-written
  const createTreeIx = SystemProgram.createAccount({
    fromPubkey: payer.publicKey,
    newAccountPubkey: treeAccount.publicKey,
    lamports: treeRent,
    space: TREE_ACCOUNT_SIZE,
    programId: PROGRAM_ID,
  });
  
  const createConfigIx = SystemProgram.createAccount({
    fromPubkey: payer.publicKey,
    newAccountPubkey: globalConfig.publicKey,
    lamports: configRent,
    space: GLOBAL_CONFIG_SIZE,
    programId: PROGRAM_ID,
  });
  
  // Build initialize instruction data
  // Args: max_deposit_amount (u64), fee_recipient (pubkey)
  const maxDepositAmount = BigInt(100 * 1e9); // 100 SOL max per deposit
  const feeRecipient = payer.publicKey;
  
  const initData = Buffer.alloc(8 + 8 + 32);
  INITIALIZE_DISCRIMINATOR.copy(initData, 0);
  initData.writeBigUInt64LE(maxDepositAmount, 8);
  feeRecipient.toBuffer().copy(initData, 16);
  
  // Initialize instruction (3 accounts: tree_account, global_config, authority)
  const initializeIx = new TransactionInstruction({
    keys: [
      { pubkey: treeAccount.publicKey, isSigner: false, isWritable: true },
      { pubkey: globalConfig.publicKey, isSigner: false, isWritable: true },
      { pubkey: payer.publicKey, isSigner: true, isWritable: true },
    ],
    programId: PROGRAM_ID,
    data: initData,
  });
  
  // We need to write discriminators BEFORE calling initialize
  // But we can't do that in one tx because the program will validate them
  // Solution: Create accounts first, then initialize in a second tx
  
  // Actually, we need to write the discriminator as part of the create
  // But SystemProgram.createAccount doesn't allow that
  // 
  // Alternative approach: Use a "raw" account without discriminator check
  // Let's try creating the accounts first
  
  console.log('\nStep 1: Creating accounts...');
  
  const createTx = new Transaction()
    .add(ComputeBudgetProgram.setComputeUnitLimit({ units: 200000 }))
    .add(createTreeIx)
    .add(createConfigIx);
  
  try {
    const createSig = await sendAndConfirmTransaction(
      connection,
      createTx,
      [payer, treeAccount, globalConfig],
      { commitment: 'confirmed' }
    );
    console.log('Create accounts tx:', createSig);
  } catch (error: any) {
    console.error('Failed to create accounts:', error.message);
    return;
  }
  
  // Now write discriminators directly to the accounts
  console.log('\nStep 2: Writing discriminators...');
  
  // We need a separate instruction to write to the account data
  // Since the accounts are owned by our program, we need our program to do it
  // But we don't have an instruction for that...
  
  // Actually, let's check if the initialize instruction can handle uninitialized accounts
  // The program uses zero.Account which checks discriminator
  // We need to either:
  // 1. Add a "setup" instruction that writes discriminators
  // 2. Use zero.Mut instead of zero.Account for initialize
  // 3. Modify the program to handle zero-discriminator on init
  
  // For now, let's try calling initialize and see what error we get
  console.log('\nStep 3: Calling initialize...');
  
  const initTx = new Transaction()
    .add(ComputeBudgetProgram.setComputeUnitLimit({ units: 400000 }))
    .add(initializeIx);
  
  try {
    const initSig = await sendAndConfirmTransaction(
      connection,
      initTx,
      [payer],
      { commitment: 'confirmed' }
    );
    
    console.log('\n✅ Initialization successful!');
    console.log('Signature:', initSig);
    console.log('Explorer:', `https://explorer.solana.com/tx/${initSig}?cluster=testnet`);
    
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
    
  } catch (error: any) {
    console.error('\n❌ Initialize failed:', error.message);
    if (error.logs) {
      console.log('\nProgram logs:');
      error.logs.forEach((log: string) => console.log('  ', log));
    }
  }
}

main().catch(console.error);
