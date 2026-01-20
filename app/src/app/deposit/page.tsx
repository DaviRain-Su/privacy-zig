'use client';

import { useState, useEffect } from 'react';
import { useConnection, useWallet } from '@solana/wallet-adapter-react';
import { LAMPORTS_PER_SOL } from '@solana/web3.js';
import dynamic from 'next/dynamic';
import Link from 'next/link';
import { deposit, getPoolStats } from '@/lib/privacy';

const WalletMultiButton = dynamic(
  () => import('@solana/wallet-adapter-react-ui').then(mod => mod.WalletMultiButton),
  { ssr: false }
);

export default function DepositPage() {
  const { connection } = useConnection();
  const { publicKey, sendTransaction, connected } = useWallet();
  
  const [amount, setAmount] = useState('0.01');
  const [status, setStatus] = useState<'idle' | 'processing' | 'success' | 'error'>('idle');
  const [progress, setProgress] = useState('');
  const [result, setResult] = useState<{ signature?: string; error?: string }>({});
  const [stats, setStats] = useState<{ poolBalance: number; totalDeposits: number } | null>(null);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  useEffect(() => {
    if (mounted) {
      getPoolStats(connection).then(setStats).catch(console.error);
    }
  }, [connection, mounted]);

  const handleDeposit = async () => {
    if (!publicKey || !connected) return;
    
    const amountLamports = Math.floor(parseFloat(amount) * LAMPORTS_PER_SOL);
    if (amountLamports <= 0) return;
    
    setStatus('processing');
    setProgress('Starting...');
    
    const res = await deposit(
      connection,
      publicKey,
      amountLamports,
      sendTransaction,
      setProgress
    );
    
    if (res.success) {
      setResult({ signature: res.signature });
      setStatus('success');
      // Refresh stats
      getPoolStats(connection).then(setStats).catch(console.error);
    } else {
      setResult({ error: res.error });
      setStatus('error');
    }
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
              <Link href="/deposit" className="text-purple-400">Deposit</Link>
              <Link href="/withdraw" className="text-gray-400 hover:text-white">Withdraw</Link>
              <Link href="/notes" className="text-gray-400 hover:text-white">Notes</Link>
            </nav>
            <WalletMultiButton className="!bg-purple-600 hover:!bg-purple-700" />
          </div>
        </div>
      </header>

      <div className="max-w-2xl mx-auto px-4 py-12">
        <h1 className="text-3xl font-bold mb-2">Deposit SOL</h1>
        <p className="text-gray-400 mb-8">
          Deposit SOL to the privacy pool. A note will be saved automatically.
        </p>

        {status === 'idle' && (
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
                {['0.01', '0.05', '0.1', '0.5', '1'].map((val) => (
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

            {/* Info */}
            <div className="bg-blue-900/20 border border-blue-800/50 rounded-lg p-4 text-sm text-blue-300">
              <p>💡 Your deposit will generate a private note stored in your browser.</p>
              <p className="mt-1">You can use this note to withdraw later to any address.</p>
            </div>

            {/* Submit */}
            <button
              onClick={handleDeposit}
              disabled={!connected || parseFloat(amount) <= 0}
              className="w-full py-4 bg-purple-600 hover:bg-purple-700 disabled:bg-gray-700 disabled:cursor-not-allowed rounded-xl font-semibold text-lg transition-colors"
            >
              {!connected ? 'Connect Wallet' : 'Deposit'}
            </button>
          </div>
        )}

        {status === 'processing' && (
          <div className="text-center py-20">
            <div className="animate-spin w-16 h-16 border-4 border-purple-500 border-t-transparent rounded-full mx-auto mb-8"></div>
            <h2 className="text-xl font-semibold mb-2">{progress}</h2>
            <p className="text-gray-500 text-sm">This may take 30-60 seconds...</p>
          </div>
        )}

        {status === 'success' && (
          <div className="text-center py-12">
            <div className="text-6xl mb-6">✅</div>
            <h2 className="text-2xl font-bold mb-4">Deposit Successful!</h2>
            <p className="text-gray-400 mb-4">{amount} SOL deposited to privacy pool</p>
            
            {/* Important Warning */}
            <div className="bg-yellow-900/30 border border-yellow-700/50 rounded-xl p-4 mb-6 text-left max-w-md mx-auto">
              <div className="flex items-start gap-3">
                <span className="text-2xl">⚠️</span>
                <div>
                  <h3 className="font-semibold text-yellow-400 mb-1">Backup Your Note!</h3>
                  <p className="text-sm text-yellow-300/80 mb-2">
                    Your note is saved in this browser only. You will <strong>lose your funds</strong> if:
                  </p>
                  <ul className="text-xs text-yellow-300/70 space-y-1 list-disc list-inside">
                    <li>You clear browser data</li>
                    <li>You use a different browser</li>
                    <li>You use a different device</li>
                  </ul>
                </div>
              </div>
            </div>

            <Link
              href="/notes"
              className="inline-block px-6 py-3 bg-yellow-600 hover:bg-yellow-700 rounded-lg font-semibold mb-4"
            >
              🔐 Backup Notes Now
            </Link>
            
            <div className="space-y-4">
              <a
                href={`https://explorer.solana.com/tx/${result.signature}?cluster=testnet`}
                target="_blank"
                rel="noopener noreferrer"
                className="block text-purple-400 hover:underline text-sm"
              >
                View transaction →
              </a>
              
              <div className="flex gap-4 justify-center">
                <button
                  onClick={() => setStatus('idle')}
                  className="px-6 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg"
                >
                  Deposit More
                </button>
                <Link
                  href="/withdraw"
                  className="px-6 py-2 bg-purple-600 hover:bg-purple-700 rounded-lg"
                >
                  Withdraw
                </Link>
              </div>
            </div>
          </div>
        )}

        {status === 'error' && (
          <div className="text-center py-12">
            <div className="text-6xl mb-6">❌</div>
            <h2 className="text-2xl font-bold mb-4">Deposit Failed</h2>
            <p className="text-gray-400 mb-8">{result.error}</p>
            <button
              onClick={() => setStatus('idle')}
              className="px-6 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg"
            >
              Try Again
            </button>
          </div>
        )}

        {/* Stats */}
        {stats && status === 'idle' && (
          <div className="mt-8 flex justify-center gap-8 text-center text-sm">
            <div>
              <div className="text-2xl font-bold text-purple-400">{stats.poolBalance.toFixed(2)}</div>
              <div className="text-gray-500">SOL in Pool</div>
            </div>
            <div>
              <div className="text-2xl font-bold">{stats.totalDeposits}</div>
              <div className="text-gray-500">Total Deposits</div>
            </div>
          </div>
        )}
      </div>
    </main>
  );
}
