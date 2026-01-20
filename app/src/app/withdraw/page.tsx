'use client';

import { useState, useEffect } from 'react';
import { useConnection, useWallet } from '@solana/wallet-adapter-react';
import { PublicKey } from '@solana/web3.js';
import dynamic from 'next/dynamic';
import Link from 'next/link';
import { withdraw } from '@/lib/privacy';
import { getWithdrawableNotes, formatAmount, Note } from '@/lib/notes';

const WalletMultiButton = dynamic(
  () => import('@solana/wallet-adapter-react-ui').then(mod => mod.WalletMultiButton),
  { ssr: false }
);

export default function WithdrawPage() {
  const { connection } = useConnection();
  const { publicKey, sendTransaction, connected } = useWallet();
  
  const [notes, setNotes] = useState<Note[]>([]);
  const [selectedNote, setSelectedNote] = useState<Note | null>(null);
  const [recipient, setRecipient] = useState('');
  const [status, setStatus] = useState<'idle' | 'processing' | 'success' | 'error'>('idle');
  const [progress, setProgress] = useState('');
  const [result, setResult] = useState<{ signature?: string; error?: string }>({});
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  useEffect(() => {
    if (mounted) {
      setNotes(getWithdrawableNotes());
    }
  }, [mounted]);

  const validateRecipient = (addr: string): boolean => {
    try {
      new PublicKey(addr);
      return true;
    } catch {
      return false;
    }
  };

  const handleWithdraw = async () => {
    if (!publicKey || !connected || !selectedNote || !validateRecipient(recipient)) return;
    
    setStatus('processing');
    setProgress('Starting...');
    
    const res = await withdraw(
      connection,
      publicKey,
      recipient,
      selectedNote,
      sendTransaction,
      setProgress
    );
    
    if (res.success) {
      setResult({ signature: res.signature });
      setStatus('success');
      // Refresh notes
      setNotes(getWithdrawableNotes());
    } else {
      setResult({ error: res.error });
      setStatus('error');
    }
  };

  const useSelfAsRecipient = () => {
    if (publicKey) {
      setRecipient(publicKey.toBase58());
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
              <Link href="/transfer" className="text-gray-400 hover:text-white">Transfer</Link>
              <Link href="/deposit" className="text-gray-400 hover:text-white">Deposit</Link>
              <Link href="/withdraw" className="text-purple-400">Withdraw</Link>
              <Link href="/notes" className="text-gray-400 hover:text-white">Notes</Link>
            </nav>
            <WalletMultiButton className="!bg-purple-600 hover:!bg-purple-700" />
          </div>
        </div>
      </header>

      <div className="max-w-2xl mx-auto px-4 py-12">
        <h1 className="text-3xl font-bold mb-2">Withdraw SOL</h1>
        <p className="text-gray-400 mb-8">
          Withdraw your deposited SOL to any address privately.
        </p>

        {status === 'idle' && (
          <div className="space-y-6">
            {/* Select Note */}
            <div className="bg-gray-900/50 rounded-2xl p-6 border border-gray-800">
              <label className="block text-sm text-gray-400 mb-4">Select Note to Withdraw</label>
              
              {notes.length === 0 ? (
                <div className="text-center py-8 text-gray-500">
                  <p>No withdrawable notes found.</p>
                  <Link href="/deposit" className="text-purple-400 hover:underline mt-2 block">
                    Make a deposit first →
                  </Link>
                </div>
              ) : (
                <div className="space-y-2">
                  {notes.map((note) => (
                    <button
                      key={note.id}
                      onClick={() => setSelectedNote(note)}
                      className={`w-full p-4 rounded-lg border text-left transition-colors ${
                        selectedNote?.id === note.id
                          ? 'border-purple-500 bg-purple-900/20'
                          : 'border-gray-700 hover:border-gray-600'
                      }`}
                    >
                      <div className="flex justify-between items-center">
                        <span className="text-xl font-mono">{formatAmount(note.amount)} SOL</span>
                        <span className="text-xs text-gray-500">
                          {new Date(note.createdAt).toLocaleDateString()}
                        </span>
                      </div>
                      <div className="text-xs text-gray-500 mt-1 truncate">
                        ID: {note.id}
                      </div>
                    </button>
                  ))}
                </div>
              )}
            </div>

            {/* Recipient */}
            {selectedNote && (
              <div className="bg-gray-900/50 rounded-2xl p-6 border border-gray-800">
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
                
                {connected && (
                  <button
                    onClick={useSelfAsRecipient}
                    className="text-purple-400 text-sm mt-2 hover:underline"
                  >
                    Use my wallet address
                  </button>
                )}
              </div>
            )}

            {/* Info */}
            {selectedNote && (
              <div className="bg-green-900/20 border border-green-800/50 rounded-lg p-4 text-sm text-green-300">
                <p>🔐 The withdrawal will be completely private.</p>
                <p className="mt-1">No one can link this withdrawal to your original deposit.</p>
              </div>
            )}

            {/* Submit */}
            <button
              onClick={handleWithdraw}
              disabled={!connected || !selectedNote || !validateRecipient(recipient)}
              className="w-full py-4 bg-purple-600 hover:bg-purple-700 disabled:bg-gray-700 disabled:cursor-not-allowed rounded-xl font-semibold text-lg transition-colors"
            >
              {!connected ? 'Connect Wallet' : !selectedNote ? 'Select a Note' : 'Withdraw'}
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
            <h2 className="text-2xl font-bold mb-4">Withdrawal Successful!</h2>
            <p className="text-gray-400 mb-8">
              {selectedNote && formatAmount(selectedNote.amount)} SOL sent to recipient
            </p>
            
            <div className="space-y-4">
              <a
                href={`https://explorer.solana.com/tx/${result.signature}?cluster=testnet`}
                target="_blank"
                rel="noopener noreferrer"
                className="block text-purple-400 hover:underline text-sm"
              >
                View transaction →
              </a>
              
              <button
                onClick={() => {
                  setStatus('idle');
                  setSelectedNote(null);
                  setRecipient('');
                }}
                className="px-6 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg"
              >
                Withdraw Another
              </button>
            </div>
          </div>
        )}

        {status === 'error' && (
          <div className="text-center py-12">
            <div className="text-6xl mb-6">❌</div>
            <h2 className="text-2xl font-bold mb-4">Withdrawal Failed</h2>
            <p className="text-gray-400 mb-8">{result.error}</p>
            <button
              onClick={() => setStatus('idle')}
              className="px-6 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg"
            >
              Try Again
            </button>
          </div>
        )}
      </div>
    </main>
  );
}
