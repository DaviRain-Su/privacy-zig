/**
 * Initialize Privacy Pool v2 on Testnet
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

// New Program ID
const PROGRAM_ID = new PublicKey('9A6fck3xNW2C6vwwqM4i1f4GeYpieuB7XKpF1YFduT6h');

// Discriminator for initialize instruction
const INITIALIZE_DISCRIMINATOR = Buffer.from([175, 175, 109, 31, 13, 152, 155, 237]);

async function main() {
  console.log('=== Privacy Pool v2 Initialization ===\n');
  
  const keypairPath = process.env.HOME + '/.config/solana/id.json';
  const keypairData = JSON.parse(fs.readFileSync(keypairPath, 'utf-8'));
  const payer = Keypair.fromSecretKey(Uint8Array.from(keypairData));
  
  const connection = new Connection('https://api.testnet.solana.com', 'confirmed');
  const balance = await connection.getBalance(payer.publicKey);
  
  console.log('Payer:', payer.publicKey.toBase58());
  console.log('Balance:', balance / LAMPORTS_PER_SOL, 'SOL');
  console.log('Program ID:', PROGRAM_ID.toBase58(), '\n');
  
  // Generate new keypairs for accounts (not PDAs for this version)
  const treeAccount = Keypair.generate();
  const globalConfig = Keypair.generate();
  
  console.log('Tree Account:', treeAccount.publicKey.toBase58());
  console.log('Global Config:', globalConfig.publicKey.toBase58());
  
  // Derive pool vault PDA
  const [poolVault] = PublicKey.findProgramAddressSync(
    [Buffer.from('pool_vault')],
    PROGRAM_ID
  );
  console.log('Pool Vault (PDA):', poolVault.toBase58());
  
  // Build initialize instruction data
  const maxDepositAmount = BigInt(100 * LAMPORTS_PER_SOL);
  const feeRecipient = payer.publicKey;
  
  const data = Buffer.alloc(8 + 8 + 32);
  INITIALIZE_DISCRIMINATOR.copy(data, 0);
  data.writeBigUInt64LE(maxDepositAmount, 8);
  feeRecipient.toBuffer().copy(data, 16);
  
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
  
  const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({
    units: 400000,
  });
  
  const tx = new Transaction().add(computeBudgetIx).add(initializeIx);
  
  console.log('\nSending transaction...');
  
  const signature = await sendAndConfirmTransaction(
    connection,
    tx,
    [payer, treeAccount, globalConfig],
    { commitment: 'confirmed' }
  );
  
  console.log('\n✅ Initialization successful!');
  console.log('Signature:', signature);
  
  // Save config
  const config = {
    programId: PROGRAM_ID.toBase58(),
    treeAccount: treeAccount.publicKey.toBase58(),
    globalConfig: globalConfig.publicKey.toBase58(),
    poolVault: poolVault.toBase58(),
    feeRecipient: feeRecipient.toBase58(),
  };
  
  fs.writeFileSync('deployed-config-v2.json', JSON.stringify(config, null, 2));
  console.log('\n📁 Config saved to deployed-config-v2.json');
  console.log(JSON.stringify(config, null, 2));
}

main().catch(console.error);
