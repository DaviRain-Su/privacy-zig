'use client';

import { useState, useEffect } from 'react';
import { useConnection, useWallet } from '@solana/wallet-adapter-react';
import { LAMPORTS_PER_SOL, PublicKey } from '@solana/web3.js';
import dynamic from 'next/dynamic';
import { 
  anonymousTransfer, 
  getPoolStats,
  TransferProgress 
} from '@/lib/privacy';

// Dynamic import to avoid hydration issues
const WalletMultiButton = dynamic(
  () => import('@solana/wallet-adapter-react-ui').then(mod => mod.WalletMultiButton),
  { ssr: false }
);

type Step = 'input' | 'processing' | 'success' | 'error';

export default function Home() {
  const { connection } = useConnection();
  const { publicKey, sendTransaction, connected } = useWallet();
  
  const [recipient, setRecipient] = useState('');
  const [amount, setAmount] = useState('0.01');
  const [step, setStep] = useState<Step>('input');
  const [progress, setProgress] = useState<TransferProgress | null>(null);
  const [result, setResult] = useState<{ depositSig?: string; withdrawSig?: string } | null>(null);
  const [error, setError] = useState('');
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
    if (!publicKey || !connected) {
      setError('Please connect your wallet');
      return;
    }
    
    if (!validateRecipient(recipient)) {
      setError('Invalid recipient address');
      return;
    }
    
    const amountLamports = Math.floor(parseFloat(amount) * LAMPORTS_PER_SOL);
    if (amountLamports <= 0) {
      setError('Invalid amount');
      return;
    }
    
    setStep('processing');
    setError('');
    setProgress({ step: 'init', message: 'Starting...' });
    
    const transferResult = await anonymousTransfer(
      connection,
      publicKey,
      recipient,
      amountLamports,
      sendTransaction,
      setProgress
    );
    
    if (transferResult.success) {
      setResult({
        depositSig: transferResult.depositSignature,
        withdrawSig: transferResult.withdrawSignature,
      });
      setStep('success');
    } else {
      setError(transferResult.error || 'Transfer failed');
      setStep('error');
    }
  };

  const reset = () => {
    setStep('input');
    setProgress(null);
    setResult(null);
    setError('');
    setRecipient('');
  };

  // Don't render until mounted to avoid hydration issues
  if (!mounted) {
    return (
      <main className="min-h-screen bg-black text-white flex items-center justify-center">
        <div className="text-gray-500">Loading...</div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-black text-white">
      {/* Header */}
      <header className="border-b border-gray-800 p-4">
        <div className="max-w-2xl mx-auto flex justify-between items-center">
          <div className="flex items-center gap-2">
            <span className="text-2xl">🔒</span>
            <span className="font-bold text-xl text-purple-400">Anonymous Transfer</span>
          </div>
          <WalletMultiButton className="!bg-purple-600 hover:!bg-purple-700" />
        </div>
      </header>

      <div className="max-w-2xl mx-auto px-4 py-12">
        
        {step === 'input' && (
          <>
            {/* Hero */}
            <div className="text-center mb-12">
              <h1 className="text-4xl font-bold mb-4">
                Send SOL <span className="text-purple-400">Privately</span>
              </h1>
              <p className="text-gray-400">
                No on-chain link between you and the recipient
              </p>
            </div>

            {/* Transfer Form */}
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
                  <span className="absolute right-4 top-1/2 -translate-y-1/2 text-gray-500 text-xl">
                    SOL
                  </span>
                </div>
                <div className="flex gap-2 mt-2">
                  {['0.01', '0.05', '0.1', '0.5'].map((val) => (
                    <button
                      key={val}
                      onClick={() => setAmount(val)}
                      className="px-3 py-1 bg-gray-800 hover:bg-gray-700 rounded text-sm"
                    >
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

              {/* Error */}
              {error && (
                <div className="bg-red-900/30 border border-red-700/50 rounded-lg p-3 text-red-300 text-sm">
                  {error}
                </div>
              )}

              {/* Send Button */}
              <button
                onClick={handleTransfer}
                disabled={!connected || !recipient || !validateRecipient(recipient)}
                className="w-full py-4 bg-purple-600 hover:bg-purple-700 disabled:bg-gray-700 disabled:cursor-not-allowed rounded-xl font-semibold text-lg transition-colors"
              >
                {!connected ? 'Connect Wallet' : 'Send Anonymously'}
              </button>
            </div>

            {/* How it works */}
            <div className="mt-8 text-center text-sm text-gray-500">
              <p className="mb-2">🔐 How it works:</p>
              <p>Your SOL passes through a privacy pool with ZK proofs.</p>
              <p>The recipient receives funds with no traceable link to you.</p>
            </div>

            {/* Stats */}
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
            
            {/* Progress Steps */}
            <div className="flex justify-center gap-2 mt-8">
              {['init', 'deposit-proof', 'deposit-tx', 'withdraw-proof', 'withdraw-tx', 'done'].map((s, i) => {
                const steps = ['init', 'deposit-proof', 'deposit-tx', 'withdraw-proof', 'withdraw-tx', 'done'];
                const currentIdx = steps.indexOf(progress.step);
                const isComplete = i < currentIdx;
                const isCurrent = s === progress.step;
                
                return (
                  <div
                    key={s}
                    className={`w-3 h-3 rounded-full ${
                      isComplete ? 'bg-purple-500' : 
                      isCurrent ? 'bg-purple-400 animate-pulse' : 
                      'bg-gray-700'
                    }`}
                  />
                );
              })}
            </div>
            
            <p className="text-gray-500 mt-4 text-sm">
              {progress.step.includes('proof') && 'Generating ZK proof (this may take 30-60 seconds)...'}
              {progress.step.includes('tx') && 'Confirm the transaction in your wallet...'}
            </p>
          </div>
        )}

        {step === 'success' && result && (
          <div className="text-center py-12">
            <div className="text-6xl mb-6">✅</div>
            <h2 className="text-3xl font-bold mb-4">Transfer Complete!</h2>
            <p className="text-gray-400 mb-8">
              {amount} SOL sent anonymously to the recipient
            </p>
            
            <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800 mb-8 text-left">
              <h3 className="font-semibold mb-4 text-green-400">🔐 Privacy Achieved</h3>
              <ul className="space-y-2 text-sm text-gray-400">
                <li>✓ No on-chain link between your wallet and recipient</li>
                <li>✓ Transaction passed through ZK privacy pool</li>
                <li>✓ Recipient could be from any of the pool depositors</li>
              </ul>
            </div>

            <div className="space-y-2 text-sm">
              <a
                href={`https://explorer.solana.com/tx/${result.withdrawSig}?cluster=testnet`}
                target="_blank"
                rel="noopener noreferrer"
                className="block text-purple-400 hover:underline"
              >
                View withdrawal on Explorer →
              </a>
            </div>

            <button
              onClick={reset}
              className="mt-8 px-8 py-3 bg-gray-800 hover:bg-gray-700 rounded-xl font-medium"
            >
              Make Another Transfer
            </button>
          </div>
        )}

        {step === 'error' && (
          <div className="text-center py-12">
            <div className="text-6xl mb-6">❌</div>
            <h2 className="text-2xl font-bold mb-4">Transfer Failed</h2>
            <p className="text-gray-400 mb-8">{error}</p>
            <button
              onClick={() => setStep('input')}
              className="px-8 py-3 bg-gray-800 hover:bg-gray-700 rounded-xl font-medium"
            >
              Try Again
            </button>
          </div>
        )}
      </div>

      {/* Footer */}
      <footer className="fixed bottom-0 left-0 right-0 p-4 text-center text-xs text-gray-600 border-t border-gray-900">
        Built with Zig • Solana Testnet • 
        <a href="https://github.com/example/privacy-zig" className="text-purple-500 hover:underline ml-1">
          Source
        </a>
      </footer>
    </main>
  );
}
