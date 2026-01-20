'use client';

import { useState, useCallback } from 'react';
import { useWallet, useConnection } from '@solana/wallet-adapter-react';
import { Header } from '@/components/Header';
import { 
  generateDepositNote, 
  serializeDepositNote, 
  saveNoteToStorage,
  DepositNote 
} from '@/lib/privacy';

export default function DepositPage() {
  const { publicKey, connected } = useWallet();
  const { connection } = useConnection();
  
  const [amount, setAmount] = useState('0.1');
  const [isLoading, setIsLoading] = useState(false);
  const [depositNote, setDepositNote] = useState<DepositNote | null>(null);
  const [noteString, setNoteString] = useState('');
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState('');

  const handleDeposit = useCallback(async () => {
    if (!connected || !publicKey) {
      setError('Please connect your wallet first');
      return;
    }

    const amountNum = parseFloat(amount);
    if (isNaN(amountNum) || amountNum <= 0) {
      setError('Please enter a valid amount');
      return;
    }

    setIsLoading(true);
    setError('');

    try {
      // Generate deposit note
      const amountLamports = BigInt(Math.floor(amountNum * 1e9));
      const note = await generateDepositNote(amountLamports);
      
      // In production, this would:
      // 1. Build the transact instruction with publicAmount > 0
      // 2. Send the transaction
      // 3. Wait for confirmation
      // 4. Parse the CommitmentData event to get leafIndex
      
      // For demo, we simulate success
      note.leafIndex = Math.floor(Math.random() * 1000);
      
      // Serialize and save
      const serialized = serializeDepositNote(note);
      saveNoteToStorage(note);
      
      setDepositNote(note);
      setNoteString(serialized);
      
    } catch (err: any) {
      setError(err.message || 'Deposit failed');
    } finally {
      setIsLoading(false);
    }
  }, [connected, publicKey, amount]);

  const copyToClipboard = useCallback(() => {
    navigator.clipboard.writeText(noteString);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, [noteString]);

  const downloadNote = useCallback(() => {
    const blob = new Blob([noteString], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `privacy-note-${Date.now()}.txt`;
    a.click();
    URL.revokeObjectURL(url);
  }, [noteString]);

  return (
    <main className="min-h-screen">
      <Header />
      
      <div className="max-w-2xl mx-auto px-4 py-12">
        <h1 className="text-3xl font-bold mb-2">Deposit SOL</h1>
        <p className="text-gray-400 mb-8">
          Deposit SOL into the privacy pool. You'll receive a secret note for withdrawal.
        </p>

        {!depositNote ? (
          <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
            {/* Amount Input */}
            <div className="mb-6">
              <label className="block text-sm font-medium mb-2">Amount (SOL)</label>
              <div className="relative">
                <input
                  type="number"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  className="w-full bg-gray-800 rounded-lg px-4 py-3 text-lg font-mono focus:outline-none focus:ring-2 focus:ring-privacy-500"
                  placeholder="0.1"
                  min="0.01"
                  step="0.01"
                />
                <span className="absolute right-4 top-1/2 -translate-y-1/2 text-gray-500">
                  SOL
                </span>
              </div>
              <p className="text-sm text-gray-500 mt-2">
                Minimum: 0.01 SOL | Maximum: 100 SOL
              </p>
            </div>

            {/* Quick amounts */}
            <div className="flex gap-2 mb-6">
              {['0.1', '0.5', '1', '5', '10'].map((val) => (
                <button
                  key={val}
                  onClick={() => setAmount(val)}
                  className={`px-4 py-2 rounded-lg transition-colors ${
                    amount === val
                      ? 'bg-privacy-600 text-white'
                      : 'bg-gray-800 text-gray-400 hover:bg-gray-700'
                  }`}
                >
                  {val} SOL
                </button>
              ))}
            </div>

            {/* Error */}
            {error && (
              <div className="mb-6 p-4 bg-red-900/30 border border-red-800 rounded-lg text-red-400">
                {error}
              </div>
            )}

            {/* Deposit Button */}
            <button
              onClick={handleDeposit}
              disabled={!connected || isLoading}
              className={`w-full py-4 rounded-lg font-semibold text-lg transition-colors ${
                connected
                  ? 'bg-privacy-600 hover:bg-privacy-700 text-white'
                  : 'bg-gray-700 text-gray-500 cursor-not-allowed'
              }`}
            >
              {!connected 
                ? 'Connect Wallet First'
                : isLoading 
                  ? 'Generating Note...' 
                  : `Deposit ${amount} SOL`
              }
            </button>

            {/* Warning */}
            <div className="mt-6 p-4 bg-yellow-900/20 border border-yellow-800/50 rounded-lg">
              <p className="text-yellow-500 text-sm">
                ⚠️ <strong>Important:</strong> After depositing, you'll receive a secret note. 
                This note is the ONLY way to withdraw your funds. Keep it safe and never share it!
              </p>
            </div>
          </div>
        ) : (
          /* Success State */
          <div className="bg-gray-900/50 rounded-xl p-6 border border-privacy-800">
            <div className="text-center mb-6">
              <div className="text-6xl mb-4">✅</div>
              <h2 className="text-2xl font-bold text-privacy-400">Deposit Successful!</h2>
              <p className="text-gray-400">Amount: {amount} SOL</p>
            </div>

            {/* Note Display */}
            <div className="mb-6">
              <label className="block text-sm font-medium mb-2 text-red-400">
                🔑 YOUR SECRET NOTE (Save this!)
              </label>
              <div className="bg-black rounded-lg p-4 font-mono text-sm break-all border border-gray-700">
                {noteString}
              </div>
            </div>

            {/* Action Buttons */}
            <div className="flex gap-4 mb-6">
              <button
                onClick={copyToClipboard}
                className="flex-1 py-3 bg-gray-800 hover:bg-gray-700 rounded-lg font-medium transition-colors"
              >
                {copied ? '✓ Copied!' : '📋 Copy Note'}
              </button>
              <button
                onClick={downloadNote}
                className="flex-1 py-3 bg-gray-800 hover:bg-gray-700 rounded-lg font-medium transition-colors"
              >
                💾 Download
              </button>
            </div>

            {/* Warning */}
            <div className="p-4 bg-red-900/30 border border-red-800 rounded-lg">
              <p className="text-red-400 text-sm">
                ⚠️ <strong>WARNING:</strong> If you lose this note, your funds are UNRECOVERABLE. 
                The note has been saved to your browser, but we recommend backing it up externally.
              </p>
            </div>

            {/* New Deposit */}
            <button
              onClick={() => {
                setDepositNote(null);
                setNoteString('');
                setAmount('0.1');
              }}
              className="w-full mt-6 py-3 bg-privacy-600 hover:bg-privacy-700 rounded-lg font-medium transition-colors"
            >
              Make Another Deposit
            </button>
          </div>
        )}
      </div>
    </main>
  );
}
