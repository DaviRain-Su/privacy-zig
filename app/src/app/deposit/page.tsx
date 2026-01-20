'use client';

import { useState, useEffect } from 'react';
import { useConnection, useWallet } from '@solana/wallet-adapter-react';
import { LAMPORTS_PER_SOL } from '@solana/web3.js';
import { Header } from '@/components/Header';
import { 
  prepareDeposit, 
  saveNoteToStorage, 
  exportNote,
  getPoolStats,
  DepositNote 
} from '@/lib/privacy';

type DepositStep = 'input' | 'generating' | 'confirming' | 'success' | 'error';

export default function DepositPage() {
  const { connection } = useConnection();
  const { publicKey, sendTransaction, connected } = useWallet();
  
  const [amount, setAmount] = useState('0.1');
  const [step, setStep] = useState<DepositStep>('input');
  const [note, setNote] = useState<DepositNote | null>(null);
  const [signature, setSignature] = useState<string>('');
  const [error, setError] = useState<string>('');
  const [poolStats, setPoolStats] = useState<{ totalDeposits: number; poolBalance: number } | null>(null);
  const [noteExported, setNoteExported] = useState(false);

  useEffect(() => {
    async function fetchStats() {
      try {
        const stats = await getPoolStats(connection);
        setPoolStats(stats);
      } catch (e) {
        console.error('Failed to fetch pool stats:', e);
      }
    }
    fetchStats();
  }, [connection]);

  const handleDeposit = async () => {
    if (!publicKey || !connected) {
      setError('Please connect your wallet first');
      return;
    }

    const amountLamports = Math.floor(parseFloat(amount) * LAMPORTS_PER_SOL);
    if (amountLamports <= 0) {
      setError('Invalid amount');
      return;
    }

    try {
      setStep('generating');
      setError('');

      // Prepare deposit transaction with ZK proof
      const { transaction, note: depositNote } = await prepareDeposit(
        connection,
        publicKey,
        amountLamports
      );

      setStep('confirming');

      // Get latest blockhash
      const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();
      transaction.recentBlockhash = blockhash;
      transaction.feePayer = publicKey;

      // Send transaction
      const sig = await sendTransaction(transaction, connection);
      
      // Confirm
      await connection.confirmTransaction({
        signature: sig,
        blockhash,
        lastValidBlockHeight,
      });

      setSignature(sig);
      setNote(depositNote);
      saveNoteToStorage(depositNote);
      setStep('success');

    } catch (e: any) {
      console.error('Deposit failed:', e);
      setError(e.message || 'Deposit failed');
      setStep('error');
    }
  };

  const handleExportNote = () => {
    if (!note) return;
    const encoded = exportNote(note);
    navigator.clipboard.writeText(encoded);
    setNoteExported(true);
    setTimeout(() => setNoteExported(false), 3000);
  };

  const handleDownloadNote = () => {
    if (!note) return;
    const blob = new Blob([JSON.stringify(note, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `privacy-note-${Date.now()}.json`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <main className="min-h-screen">
      <Header />
      
      <div className="max-w-2xl mx-auto px-4 py-12">
        <h1 className="text-4xl font-bold mb-2">Deposit SOL</h1>
        <p className="text-gray-400 mb-8">
          Deposit SOL into the privacy pool. Save your secret note carefully!
        </p>

        {/* Pool Stats */}
        {poolStats && (
          <div className="bg-gray-900/50 rounded-xl p-4 mb-8 border border-gray-800">
            <div className="flex justify-between">
              <div>
                <div className="text-sm text-gray-400">Pool Balance</div>
                <div className="text-xl font-semibold text-privacy-400">
                  {poolStats.poolBalance.toFixed(4)} SOL
                </div>
              </div>
              <div>
                <div className="text-sm text-gray-400">Total Deposits</div>
                <div className="text-xl font-semibold">{poolStats.totalDeposits}</div>
              </div>
            </div>
          </div>
        )}

        {step === 'input' && (
          <div className="space-y-6">
            {/* Amount Input */}
            <div>
              <label className="block text-sm font-medium mb-2">Amount (SOL)</label>
              <div className="relative">
                <input
                  type="number"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-3 text-xl font-mono focus:outline-none focus:border-privacy-500"
                  placeholder="0.1"
                  step="0.01"
                  min="0.01"
                />
                <div className="absolute right-4 top-1/2 -translate-y-1/2 text-gray-400">
                  SOL
                </div>
              </div>
              <div className="flex gap-2 mt-2">
                {['0.05', '0.1', '0.5', '1'].map((val) => (
                  <button
                    key={val}
                    onClick={() => setAmount(val)}
                    className="px-3 py-1 bg-gray-800 hover:bg-gray-700 rounded text-sm"
                  >
                    {val} SOL
                  </button>
                ))}
              </div>
            </div>

            {/* Warning */}
            <div className="bg-yellow-900/30 border border-yellow-700/50 rounded-lg p-4">
              <div className="flex gap-3">
                <span className="text-xl">⚠️</span>
                <div>
                  <div className="font-semibold text-yellow-200">Important</div>
                  <div className="text-sm text-yellow-200/80">
                    After depositing, you will receive a secret note. This is the ONLY way 
                    to withdraw your funds. Keep it safe and never share it!
                  </div>
                </div>
              </div>
            </div>

            {/* Error Message */}
            {error && (
              <div className="bg-red-900/30 border border-red-700/50 rounded-lg p-4 text-red-200">
                {error}
              </div>
            )}

            {/* Deposit Button */}
            <button
              onClick={handleDeposit}
              disabled={!connected}
              className="w-full py-4 bg-privacy-600 hover:bg-privacy-700 disabled:bg-gray-700 disabled:cursor-not-allowed rounded-lg font-semibold text-lg transition-colors"
            >
              {connected ? 'Deposit' : 'Connect Wallet First'}
            </button>
          </div>
        )}

        {step === 'generating' && (
          <div className="text-center py-12">
            <div className="animate-spin w-16 h-16 border-4 border-privacy-500 border-t-transparent rounded-full mx-auto mb-6"></div>
            <h2 className="text-2xl font-semibold mb-2">Generating ZK Proof</h2>
            <p className="text-gray-400">This may take a few seconds...</p>
          </div>
        )}

        {step === 'confirming' && (
          <div className="text-center py-12">
            <div className="animate-pulse w-16 h-16 bg-privacy-600 rounded-full mx-auto mb-6 flex items-center justify-center">
              <span className="text-2xl">📝</span>
            </div>
            <h2 className="text-2xl font-semibold mb-2">Confirm Transaction</h2>
            <p className="text-gray-400">Please confirm the transaction in your wallet</p>
          </div>
        )}

        {step === 'success' && note && (
          <div className="space-y-6">
            <div className="bg-green-900/30 border border-green-700/50 rounded-lg p-6 text-center">
              <div className="text-4xl mb-4">✅</div>
              <h2 className="text-2xl font-semibold mb-2">Deposit Successful!</h2>
              <p className="text-gray-400 mb-4">
                {parseFloat(amount)} SOL deposited to the privacy pool
              </p>
              <a
                href={`https://explorer.solana.com/tx/${signature}?cluster=testnet`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-privacy-400 hover:underline text-sm"
              >
                View on Explorer →
              </a>
            </div>

            {/* Secret Note */}
            <div className="bg-red-900/30 border border-red-700/50 rounded-lg p-6">
              <div className="flex items-center gap-2 mb-4">
                <span className="text-xl">🔐</span>
                <h3 className="text-xl font-semibold">Your Secret Note</h3>
              </div>
              <p className="text-sm text-gray-300 mb-4">
                This is your withdrawal key. Save it somewhere safe! Without it, you cannot 
                withdraw your funds.
              </p>
              
              <div className="bg-black/50 rounded-lg p-4 mb-4 font-mono text-xs break-all text-gray-300">
                {exportNote(note)}
              </div>
              
              <div className="flex gap-3">
                <button
                  onClick={handleExportNote}
                  className="flex-1 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg font-medium transition-colors"
                >
                  {noteExported ? '✓ Copied!' : '📋 Copy to Clipboard'}
                </button>
                <button
                  onClick={handleDownloadNote}
                  className="flex-1 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg font-medium transition-colors"
                >
                  💾 Download JSON
                </button>
              </div>
            </div>

            {/* Next Steps */}
            <div className="bg-gray-900/50 rounded-lg p-6 border border-gray-800">
              <h3 className="font-semibold mb-3">What's Next?</h3>
              <ul className="space-y-2 text-gray-400 text-sm">
                <li>• Your note is saved in browser storage (but always keep a backup!)</li>
                <li>• Wait for more deposits to increase your anonymity set</li>
                <li>• When ready, go to Withdraw and use your note</li>
                <li>• You can withdraw to ANY address with no link to this deposit</li>
              </ul>
            </div>

            <button
              onClick={() => {
                setStep('input');
                setNote(null);
                setSignature('');
              }}
              className="w-full py-3 bg-gray-800 hover:bg-gray-700 rounded-lg font-medium transition-colors"
            >
              Make Another Deposit
            </button>
          </div>
        )}

        {step === 'error' && (
          <div className="space-y-6">
            <div className="bg-red-900/30 border border-red-700/50 rounded-lg p-6 text-center">
              <div className="text-4xl mb-4">❌</div>
              <h2 className="text-2xl font-semibold mb-2">Deposit Failed</h2>
              <p className="text-gray-400">{error}</p>
            </div>

            <button
              onClick={() => {
                setStep('input');
                setError('');
              }}
              className="w-full py-3 bg-gray-800 hover:bg-gray-700 rounded-lg font-medium transition-colors"
            >
              Try Again
            </button>
          </div>
        )}
      </div>
    </main>
  );
}
