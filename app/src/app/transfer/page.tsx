'use client';

import { useState, useEffect } from 'react';
import { useConnection, useWallet } from '@solana/wallet-adapter-react';
import { LAMPORTS_PER_SOL, PublicKey, Transaction, SystemProgram, TransactionInstruction, ComputeBudgetProgram } from '@solana/web3.js';
import dynamic from 'next/dynamic';
import Link from 'next/link';
import BN from 'bn.js';
import { 
  initPoseidon, 
  poseidonHash, 
  generateBlinding, 
  generateKeypair,
  MerkleTree,
  fetchCommitmentsFromChain,
  getCurrentLeafIndex,
  getPoolStats,
  PROGRAM_ID,
  POOL_CONFIG,
  MERKLE_TREE_HEIGHT,
  FIELD_SIZE,
  BN254_FIELD_MODULUS,
  publicSignalToI64,
} from '@/lib/privacy';
import { buildExplorerTxUrl } from '@/lib/explorer';

const WalletMultiButton = dynamic(
  () => import('@solana/wallet-adapter-react-ui').then(mod => mod.WalletMultiButton),
  { ssr: false }
);

const TRANSACT_DISCRIMINATOR = new Uint8Array([217, 149, 130, 143, 221, 52, 252, 119]);

type Step = 'input' | 'processing' | 'success' | 'error';
type ProgressStep = 'init' | 'deposit-proof' | 'deposit-tx' | 'withdraw-proof' | 'withdraw-tx' | 'done';

interface Progress {
  step: ProgressStep;
  message: string;
}

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
  
  const proofA = [...Array.from(utils.leInt2Buff(negA.x, 32)).reverse(), ...Array.from(utils.leInt2Buff(negA.y, 32)).reverse()];
  const proofB = [
    ...Array.from(utils.leInt2Buff(BigInt(proof.pi_b[0][1]), 32)).reverse(),
    ...Array.from(utils.leInt2Buff(BigInt(proof.pi_b[0][0]), 32)).reverse(),
    ...Array.from(utils.leInt2Buff(BigInt(proof.pi_b[1][1]), 32)).reverse(),
    ...Array.from(utils.leInt2Buff(BigInt(proof.pi_b[1][0]), 32)).reverse(),
  ];
  const proofC = [...Array.from(utils.leInt2Buff(BigInt(proof.pi_c[0]), 32)).reverse(), ...Array.from(utils.leInt2Buff(BigInt(proof.pi_c[1]), 32)).reverse()];
  
  return Buffer.concat([Buffer.from(proofA), Buffer.from(proofB), Buffer.from(proofC)]);
}

async function serializePublicSignals(publicSignals: string[]): Promise<Buffer[]> {
  const ffjavascript = await import('ffjavascript');
  const { utils } = ffjavascript;
  return publicSignals.map(sig => Buffer.from(Array.from(utils.leInt2Buff(utils.unstringifyBigInts(sig), 32)).reverse()));
}

export default function TransferPage() {
  const { connection } = useConnection();
  const { publicKey, sendTransaction, connected } = useWallet();
  
  const [recipient, setRecipient] = useState('');
  const [amount, setAmount] = useState('0.01');
  const [step, setStep] = useState<Step>('input');
  const [progress, setProgress] = useState<Progress | null>(null);
  const [result, setResult] = useState<{ depositSig?: string; withdrawSig?: string; error?: string }>({});
  const [stats, setStats] = useState<{ totalDeposits: number; poolBalance: number } | null>(null);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  useEffect(() => {
    if (mounted) {
      getPoolStats(connection).then(setStats).catch(console.error);
    }
  }, [connection, mounted]);

  const validateRecipient = (addr: string): boolean => {
    try {
      new PublicKey(addr);
      return true;
    } catch {
      return false;
    }
  };

  const handleTransfer = async () => {
    if (!publicKey || !connected || !validateRecipient(recipient)) return;
    
    const amountLamports = Math.floor(parseFloat(amount) * LAMPORTS_PER_SOL);
    if (amountLamports <= 0) return;
    
    setStep('processing');
    setProgress({ step: 'init', message: 'Initializing...' });
    
    try {
      await initPoseidon();
      
      const solMintAddress = 1n;
      const recipientPubkey = new PublicKey(recipient);
      const utxoKeypair = generateKeypair();
      
      // Fetch current tree state for deposit root
      const existingCommitments = await fetchCommitmentsFromChain(connection);
      const tree = new MerkleTree();
      for (const c of existingCommitments) {
        tree.insert(c);
      }
      const currentLeafIndex = tree.leaves.length;
      const depositRoot = tree.getRoot();
      
      // ========== DEPOSIT ==========
      setProgress({ step: 'deposit-proof', message: 'Generating deposit proof...' });
      
      const dummyBlinding1 = generateBlinding();
      const dummyBlinding2 = generateBlinding();
      const dummyCommitment1 = poseidonHash([0n, utxoKeypair.pubkey, dummyBlinding1, solMintAddress]);
      const dummyCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, dummyBlinding2, solMintAddress]);
      const dummySig1 = poseidonHash([utxoKeypair.privkey, dummyCommitment1, 0n]);
      const dummySig2 = poseidonHash([utxoKeypair.privkey, dummyCommitment2, 0n]);
      const inputNullifier1 = poseidonHash([dummyCommitment1, 0n, dummySig1]);
      const inputNullifier2 = poseidonHash([dummyCommitment2, 0n, dummySig2]);
      
      const outBlinding1 = generateBlinding();
      const outBlinding2 = generateBlinding();
      const outputCommitment1 = poseidonHash([BigInt(amountLamports), utxoKeypair.pubkey, outBlinding1, solMintAddress]);
      const outputCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, outBlinding2, solMintAddress]);
      
      const depositPublicAmountField = new BN(amountLamports).add(FIELD_SIZE).mod(FIELD_SIZE);
      const senderNum = BigInt('0x' + publicKey.toBuffer().toString('hex').slice(0, 16));
      const depositExtDataHash = poseidonHash([senderNum, BigInt(amountLamports)]);
      
      const zeroPath = new Array(MERKLE_TREE_HEIGHT).fill('0');
      const depositInput = {
        root: depositRoot.toString(),
        publicAmount: depositPublicAmountField.toString(),
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
      
      const depositProofResult = await generateProof(depositInput);
      const depositProofBuffer = await serializeProof(depositProofResult.proof);
      const depositPublicInputs = await serializePublicSignals(depositProofResult.publicSignals);
      
      const depositData = Buffer.alloc(8 + 256 + 32 * 5 + 8 + 32);
      let offset = 0;
      Buffer.from(TRANSACT_DISCRIMINATOR).copy(depositData, offset); offset += 8;
      depositProofBuffer.copy(depositData, offset); offset += 256;
      depositPublicInputs[0].copy(depositData, offset); offset += 32;
      depositPublicInputs[3].copy(depositData, offset); offset += 32;
      depositPublicInputs[4].copy(depositData, offset); offset += 32;
      depositPublicInputs[5].copy(depositData, offset); offset += 32;
      depositPublicInputs[6].copy(depositData, offset); offset += 32;
      const depositPublicAmount = publicSignalToI64(depositProofResult.publicSignals[1]);
      depositData.writeBigInt64LE(depositPublicAmount, offset); offset += 8;
      depositPublicInputs[2].copy(depositData, offset);
      
      const [depositNull1PDA] = PublicKey.findProgramAddressSync([Buffer.from('nullifier'), depositPublicInputs[3]], PROGRAM_ID);
      const [depositNull2PDA] = PublicKey.findProgramAddressSync([Buffer.from('nullifier'), depositPublicInputs[4]], PROGRAM_ID);
      const [poolVault] = PublicKey.findProgramAddressSync([Buffer.from('pool_vault')], PROGRAM_ID);
      
      // 9 accounts: tree, null1, null2, config, vault, signer, recipient, fee_recipient, system
      const depositIx = new TransactionInstruction({
        keys: [
          { pubkey: POOL_CONFIG.treeAccount, isSigner: false, isWritable: true },
          { pubkey: depositNull1PDA, isSigner: false, isWritable: true },
          { pubkey: depositNull2PDA, isSigner: false, isWritable: true },
          { pubkey: POOL_CONFIG.globalConfig, isSigner: false, isWritable: false },
          { pubkey: poolVault, isSigner: false, isWritable: true },
          { pubkey: publicKey, isSigner: true, isWritable: true },           // signer
          { pubkey: publicKey, isSigner: false, isWritable: true },          // recipient (same for deposit)
          { pubkey: POOL_CONFIG.feeRecipient, isSigner: false, isWritable: true },
          { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
        ],
        programId: PROGRAM_ID,
        data: depositData,
      });
      
      setProgress({ step: 'deposit-tx', message: 'Sending deposit transaction...' });
      
      const depositTx = new Transaction()
        .add(ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 }))
        .add(depositIx);
      
      const { blockhash: depositBlockhash, lastValidBlockHeight: depositHeight } = await connection.getLatestBlockhash();
      depositTx.recentBlockhash = depositBlockhash;
      depositTx.feePayer = publicKey;
      
      const depositSig = await sendTransaction(depositTx, connection);
      await connection.confirmTransaction({ signature: depositSig, blockhash: depositBlockhash, lastValidBlockHeight: depositHeight });
      
      // ========== WITHDRAW ==========
      setProgress({ step: 'withdraw-proof', message: 'Generating withdrawal proof...' });
      
      await new Promise(r => setTimeout(r, 3000));
      
      const commitments = await fetchCommitmentsFromChain(connection);
      const withdrawTree = new MerkleTree();
      for (const c of commitments) {
        withdrawTree.insert(c);
      }
      
      let leafIndex = withdrawTree.findLeafIndex(outputCommitment1);
      if (leafIndex === -1) {
        leafIndex = currentLeafIndex;
        withdrawTree.insert(outputCommitment1);
        withdrawTree.insert(outputCommitment2);
      }
      
      const { pathElements } = withdrawTree.getPath(leafIndex);
      const withdrawRoot = withdrawTree.getRoot();
      
      const signature = poseidonHash([utxoKeypair.privkey, outputCommitment1, BigInt(leafIndex)]);
      const withdrawNullifier = poseidonHash([outputCommitment1, BigInt(leafIndex), signature]);
      
      const withdrawDummyBlinding = generateBlinding();
      const withdrawDummyCommitment = poseidonHash([0n, utxoKeypair.pubkey, withdrawDummyBlinding, solMintAddress]);
      const withdrawDummySig = poseidonHash([utxoKeypair.privkey, withdrawDummyCommitment, 0n]);
      const withdrawDummyNullifier = poseidonHash([withdrawDummyCommitment, 0n, withdrawDummySig]);
      
      const withdrawOutBlinding1 = generateBlinding();
      const withdrawOutBlinding2 = generateBlinding();
      const withdrawOutputCommitment1 = poseidonHash([0n, utxoKeypair.pubkey, withdrawOutBlinding1, solMintAddress]);
      const withdrawOutputCommitment2 = poseidonHash([0n, utxoKeypair.pubkey, withdrawOutBlinding2, solMintAddress]);
      
      const withdrawPublicAmountField = new BN(amountLamports).neg().add(FIELD_SIZE).mod(FIELD_SIZE);
      const recipientNum = BigInt('0x' + recipientPubkey.toBuffer().slice(0, 8).toString('hex'));
      const withdrawExtDataHash = poseidonHash([recipientNum, BigInt(amountLamports)]);
      
      const withdrawInput = {
        root: withdrawRoot.toString(),
        publicAmount: withdrawPublicAmountField.toString(),
        extDataHash: withdrawExtDataHash.toString(),
        mintAddress: solMintAddress.toString(),
        inputNullifier: [withdrawNullifier.toString(), withdrawDummyNullifier.toString()],
        inAmount: [amountLamports.toString(), '0'],
        inPrivateKey: [utxoKeypair.privkey.toString(), utxoKeypair.privkey.toString()],
        inBlinding: [outBlinding1.toString(), withdrawDummyBlinding.toString()],
        inPathIndices: [leafIndex, 0],
        inPathElements: [pathElements.map(e => e.toString()), new Array(MERKLE_TREE_HEIGHT).fill('0')],
        outputCommitment: [withdrawOutputCommitment1.toString(), withdrawOutputCommitment2.toString()],
        outAmount: ['0', '0'],
        outPubkey: [utxoKeypair.pubkey.toString(), utxoKeypair.pubkey.toString()],
        outBlinding: [withdrawOutBlinding1.toString(), withdrawOutBlinding2.toString()],
      };
      
      const withdrawProofResult = await generateProof(withdrawInput);
      const withdrawProofBuffer = await serializeProof(withdrawProofResult.proof);
      const withdrawPublicInputs = await serializePublicSignals(withdrawProofResult.publicSignals);
      
      const withdrawData = Buffer.alloc(8 + 256 + 32 * 5 + 8 + 32);
      offset = 0;
      Buffer.from(TRANSACT_DISCRIMINATOR).copy(withdrawData, offset); offset += 8;
      withdrawProofBuffer.copy(withdrawData, offset); offset += 256;
      withdrawPublicInputs[0].copy(withdrawData, offset); offset += 32;
      withdrawPublicInputs[3].copy(withdrawData, offset); offset += 32;
      withdrawPublicInputs[4].copy(withdrawData, offset); offset += 32;
      withdrawPublicInputs[5].copy(withdrawData, offset); offset += 32;
      withdrawPublicInputs[6].copy(withdrawData, offset); offset += 32;
      const withdrawPublicAmount = publicSignalToI64(withdrawProofResult.publicSignals[1]);
      withdrawData.writeBigInt64LE(withdrawPublicAmount, offset); offset += 8;
      withdrawPublicInputs[2].copy(withdrawData, offset);
      
      setProgress({ step: 'withdraw-tx', message: 'Sending via relayer for privacy...' });
      
      // Use relayer for withdraw - relayer signs so user address is hidden!
      const RELAYER_URL = process.env.NEXT_PUBLIC_RELAYER_URL || 'http://localhost:3001';
      
      const relayResponse = await fetch(`${RELAYER_URL}/relay`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          instruction_data: Buffer.from(withdrawData).toString('base64'),
          nullifier1: Buffer.from(withdrawPublicInputs[3]).toString('hex'),
          nullifier2: Buffer.from(withdrawPublicInputs[4]).toString('hex'),
          recipient: recipient,
        }),
      });
      
      const relayResult = await relayResponse.json();
      
      if (!relayResult.success) {
        throw new Error(relayResult.error || 'Relayer failed');
      }
      
      const withdrawSig = relayResult.signature;
      await connection.confirmTransaction(withdrawSig, 'confirmed');
      
      setProgress({ step: 'done', message: 'Transfer complete!' });
      setResult({ depositSig, withdrawSig });
      setStep('success');
      getPoolStats(connection).then(setStats).catch(console.error);
      
    } catch (error: any) {
      console.error('Transfer error:', error);
      setResult({ error: error.message });
      setStep('error');
    }
  };

  const reset = () => {
    setStep('input');
    setProgress(null);
    setResult({});
    setRecipient('');
  };

  if (!mounted) {
    return <div className="min-h-screen bg-black text-white flex items-center justify-center">Loading...</div>;
  }

  return (
    <main className="min-h-screen bg-black text-white">
      {/* Header */}
      <header className="border-b border-gray-800 p-4">
        <div className="max-w-2xl mx-auto flex justify-between items-center">
          <Link href="/" className="flex items-center gap-2 hover:opacity-80">
            <span className="text-2xl">🔒</span>
            <span className="font-bold text-xl text-purple-400">Privacy Pool</span>
          </Link>
          <div className="flex items-center gap-4">
            <nav className="flex gap-4 text-sm">
              <Link href="/deposit" className="text-gray-400 hover:text-white">Deposit</Link>
              <Link href="/withdraw" className="text-gray-400 hover:text-white">Withdraw</Link>
              <Link href="/transfer" className="text-purple-400">Transfer</Link>
              <Link href="/notes" className="text-gray-400 hover:text-white">Notes</Link>
            </nav>
            <WalletMultiButton className="!bg-purple-600 hover:!bg-purple-700" />
          </div>
        </div>
      </header>

      <div className="max-w-2xl mx-auto px-4 py-12">
        {step === 'input' && (
          <>
            <div className="text-center mb-8">
              <h1 className="text-3xl font-bold mb-2">
                Anonymous <span className="text-purple-400">Transfer</span>
              </h1>
              <p className="text-gray-400">
                Send SOL privately in one click. No notes to manage.
              </p>
            </div>

            <div className="bg-gray-900/50 rounded-2xl p-6 border border-gray-800 space-y-6">
              {/* Amount */}
              <div>
                <label className="block text-sm text-gray-400 mb-2">Amount</label>
                <div className="relative">
                  <input
                    type="number"
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    className="w-full bg-black border border-gray-700 rounded-xl px-4 py-4 text-2xl font-mono focus:outline-none focus:border-purple-500"
                    placeholder="0.00"
                    step="0.01"
                    min="0.001"
                  />
                  <span className="absolute right-4 top-1/2 -translate-y-1/2 text-gray-500 text-xl">SOL</span>
                </div>
                <div className="flex gap-2 mt-2">
                  {['0.01', '0.05', '0.1', '0.5'].map((val) => (
                    <button key={val} onClick={() => setAmount(val)} className="px-3 py-1 bg-gray-800 hover:bg-gray-700 rounded text-sm">
                      {val}
                    </button>
                  ))}
                </div>
              </div>

              {/* Recipient */}
              <div>
                <label className="block text-sm text-gray-400 mb-2">Recipient Address</label>
                <input
                  type="text"
                  value={recipient}
                  onChange={(e) => setRecipient(e.target.value)}
                  className="w-full bg-black border border-gray-700 rounded-xl px-4 py-4 font-mono text-sm focus:outline-none focus:border-purple-500"
                  placeholder="Enter Solana wallet address..."
                />
                {recipient && !validateRecipient(recipient) && (
                  <p className="text-red-400 text-sm mt-1">Invalid address</p>
                )}
              </div>

              {/* Info */}
              <div className="bg-blue-900/20 border border-blue-800/50 rounded-lg p-4 text-sm text-blue-300">
                <p>🔐 This will deposit and withdraw in two transactions.</p>
                <p className="mt-1">The recipient receives funds with no link to you.</p>
              </div>

              {/* Submit */}
              <button
                onClick={handleTransfer}
                disabled={!connected || !recipient || !validateRecipient(recipient)}
                className="w-full py-4 bg-purple-600 hover:bg-purple-700 disabled:bg-gray-700 disabled:cursor-not-allowed rounded-xl font-semibold text-lg transition-colors"
              >
                {!connected ? 'Connect Wallet' : 'Send Anonymously'}
              </button>
            </div>

            {stats && (
              <div className="mt-8 flex justify-center gap-8 text-center text-sm">
                <div>
                  <div className="text-2xl font-bold text-purple-400">{stats.poolBalance.toFixed(2)}</div>
                  <div className="text-gray-500">SOL in Pool</div>
                </div>
                <div>
                  <div className="text-2xl font-bold">{stats.totalDeposits}</div>
                  <div className="text-gray-500">Transactions</div>
                </div>
              </div>
            )}
          </>
        )}

        {step === 'processing' && progress && (
          <div className="text-center py-20">
            <div className="animate-spin w-16 h-16 border-4 border-purple-500 border-t-transparent rounded-full mx-auto mb-8"></div>
            <h2 className="text-2xl font-semibold mb-4">{progress.message}</h2>
            
            <div className="flex justify-center gap-2 mt-8">
              {(['init', 'deposit-proof', 'deposit-tx', 'withdraw-proof', 'withdraw-tx', 'done'] as ProgressStep[]).map((s, i) => {
                const steps: ProgressStep[] = ['init', 'deposit-proof', 'deposit-tx', 'withdraw-proof', 'withdraw-tx', 'done'];
                const currentIdx = steps.indexOf(progress.step);
                const isComplete = i < currentIdx;
                const isCurrent = s === progress.step;
                
                return (
                  <div
                    key={s}
                    className={`w-3 h-3 rounded-full ${
                      isComplete ? 'bg-purple-500' : isCurrent ? 'bg-purple-400 animate-pulse' : 'bg-gray-700'
                    }`}
                  />
                );
              })}
            </div>
            
            <p className="text-gray-500 mt-4 text-sm">
              {progress.step.includes('proof') && 'Generating ZK proof (30-60 seconds)...'}
              {progress.step.includes('tx') && 'Confirm in your wallet...'}
            </p>
          </div>
        )}

        {step === 'success' && (
          <div className="text-center py-12">
            <div className="text-6xl mb-6">✅</div>
            <h2 className="text-3xl font-bold mb-4">Transfer Complete!</h2>
            <p className="text-gray-400 mb-8">{amount} SOL sent anonymously</p>
            
            <div className="bg-green-900/30 rounded-xl p-6 border border-green-800/50 mb-8 text-left max-w-md mx-auto">
              <h3 className="font-semibold mb-4 text-green-400">🔐 Privacy Achieved</h3>
              <ul className="space-y-2 text-sm text-gray-400">
                <li>✓ No on-chain link between you and recipient</li>
                <li>✓ Passed through ZK privacy pool</li>
                <li>✓ No notes to manage</li>
              </ul>
            </div>

            <div className="space-y-2 text-sm">
              <a
                href={result.withdrawSig ? buildExplorerTxUrl(result.withdrawSig) : '#'}
                target="_blank"
                rel="noopener noreferrer"
                className="block text-purple-400 hover:underline"
              >
                View withdrawal on Explorer →
              </a>
            </div>

            <button onClick={reset} className="mt-8 px-8 py-3 bg-gray-800 hover:bg-gray-700 rounded-xl font-medium">
              Make Another Transfer
            </button>
          </div>
        )}

        {step === 'error' && (
          <div className="text-center py-12">
            <div className="text-6xl mb-6">❌</div>
            <h2 className="text-2xl font-bold mb-4">Transfer Failed</h2>
            <p className="text-gray-400 mb-8">{result.error}</p>
            <button onClick={() => setStep('input')} className="px-8 py-3 bg-gray-800 hover:bg-gray-700 rounded-xl font-medium">
              Try Again
            </button>
          </div>
        )}
      </div>
    </main>
  );
}
