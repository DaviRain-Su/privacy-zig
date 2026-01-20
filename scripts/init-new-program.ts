/**
 * Initialize new privacy-pool program
 */

import {
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
  sendAndConfirmTransaction,
} from '@solana/web3.js';
import * as fs from 'fs';

const NEW_PROGRAM_ID = new PublicKey('9A6fck3xNW2C6vwwqM4i1f4GeYpieuB7XKpF1YFduT6h');
const INIT_DISCRIMINATOR = Buffer.from([175, 175, 109, 31, 13, 152, 155, 237]);

async function main() {
  const connection = new Connection('https://api.testnet.solana.com', 'confirmed');
  
  const keypairPath = process.env.HOME + '/.config/solana/id.json';
  const keypairData = JSON.parse(fs.readFileSync(keypairPath, 'utf-8'));
  const payer = Keypair.fromSecretKey(Uint8Array.from(keypairData));
  
  console.log('Payer:', payer.publicKey.toBase58());
  console.log('Program ID:', NEW_PROGRAM_ID.toBase58());
  
  // Derive PDAs
  const [treeAccount] = PublicKey.findProgramAddressSync(
    [Buffer.from('merkle_tree')],
    NEW_PROGRAM_ID
  );
  const [globalConfig] = PublicKey.findProgramAddressSync(
    [Buffer.from('global_config')],
    NEW_PROGRAM_ID
  );
  const [poolVault] = PublicKey.findProgramAddressSync(
    [Buffer.from('pool_vault')],
    NEW_PROGRAM_ID
  );
  
  console.log('\nDerived PDAs:');
  console.log('  Tree Account:', treeAccount.toBase58());
  console.log('  Global Config:', globalConfig.toBase58());
  console.log('  Pool Vault:', poolVault.toBase58());
  
  // Check if already initialized
  const treeInfo = await connection.getAccountInfo(treeAccount);
  if (treeInfo) {
    console.log('\n⚠️  Already initialized!');
    return;
  }
  
  // Build init instruction
  const initData = Buffer.alloc(8);
  INIT_DISCRIMINATOR.copy(initData, 0);
  
  const initIx = new TransactionInstruction({
    keys: [
      { pubkey: treeAccount, isSigner: false, isWritable: true },
      { pubkey: globalConfig, isSigner: false, isWritable: true },
      { pubkey: payer.publicKey, isSigner: true, isWritable: true },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    programId: NEW_PROGRAM_ID,
    data: initData,
  });
  
  const tx = new Transaction().add(initIx);
  
  console.log('\nSending initialization transaction...');
  const sig = await sendAndConfirmTransaction(connection, tx, [payer]);
  console.log('Signature:', sig);
  
  console.log('\n✅ Initialization complete!');
  console.log('\nUpdate these in CLI pool.rs:');
  console.log(`  program_id: "${NEW_PROGRAM_ID.toBase58()}"`);
  console.log(`  tree_account: "${treeAccount.toBase58()}"`);
  console.log(`  global_config: "${globalConfig.toBase58()}"`);
  console.log(`  pool_vault: "${poolVault.toBase58()}"`);
}

main().catch(console.error);
