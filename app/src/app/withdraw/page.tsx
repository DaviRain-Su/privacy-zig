'use client';

import { useState, useEffect } from 'react';
import { useConnection, useWallet } from '@solana/wallet-adapter-react';
import { PublicKey, LAMPORTS_PER_SOL } from '@solana/web3.js';
import { Header } from '@/components/Header';
import { 
  prepareWithdraw, 
  getNotesFromStorage, 
  removeNoteFromStorage,
  importNote,
  getPoolStats,
  DepositNote 
} from '@/lib/privacy';

type WithdrawStep = 'select' | 'input' | 'generating' | 'confirming' | 'success' | 'error';

export default function WithdrawPage() {
  const { connection } = useConnection();
  const { publicKey, sendTransaction, connected } = useWallet();
  
  const [step, setStep] = useState<WithdrawStep>('select');
  const [notes, setNotes] = useState<DepositNote[]>([]);
  const [selectedNote, setSelectedNote] = useState<DepositNote | null>(null);
  const [recipient, setRecipient] = useState('');
  const [importedNote, setImportedNote] = useState('');
  const [signature, setSignature] = useState('');
  const [error, setError] = useState('');
  const [poolStats, setPoolStats] = useState<{ totalDeposits: number; poolBalance: number } | null>(null);

  useEffect(() => {
    setNotes(getNotesFromStorage());
  }, []);

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

  useEffect(() => {
    if (publicKey) {
      setRecipient(publicKey.toBase58());
    }
  }, [publicKey]);

  const handleSelectNote = (note: DepositNote) => {
    setSelectedNote(note);
    setStep('input');
  };

  const handleImportNote = () => {
    try {
      const note = importNote(importedNote);
      setSelectedNote(note);
      setStep('input');
    } catch (e) {
      setError('Invalid note format');
    }
  };

  const handleWithdraw = async () => {
    if (!publicKey || !connected || !selectedNote) {
      setError('Please connect your wallet and select a note');
      return;
    }

    let recipientPubkey: PublicKey;
    try {
      recipientPubkey = new PublicKey(recipient);
    } catch {
      setError('Invalid recipient address');
      return;
    }

    try {
      setStep('generating');
      setError('');

      // Prepare withdraw transaction
      const transaction = await prepareWithdraw(
        connection,
        selectedNote,
        recipientPubkey,
        publicKey
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
      
      // Remove used note from storage
      removeNoteFromStorage(selectedNote.commitment);
      setNotes(getNotesFromStorage());
      
      setStep('success');

    } catch (e: any) {
      console.error('Withdraw failed:', e);
      setError(e.message || 'Withdrawal failed');
      setStep('error');
    }
  };

  return (
    <main className="min-h-screen">
      <Header />
      
      <div className="max-w-2xl mx-auto px-4 py-12">
        <h1 className="text-4xl font-bold mb-2">Withdraw SOL</h1>
        <p className="text-gray-400 mb-8">
          Use your secret note to withdraw SOL to any address anonymously.
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
                <div className="text-sm text-gray-400">Anonymity Set</div>
                <div className="text-xl font-semibold">{poolStats.totalDeposits} deposits</div>
              </div>
            </div>
          </div>
        )}

        {step === 'select' && (
          <div className="space-y-6">
            {/* Saved Notes */}
            {notes.length > 0 && (
              <div>
                <h3 className="text-lg font-semibold mb-3">Your Saved Notes</h3>
                <div className="space-y-3">
                  {notes.map((note, idx) => (
                    <button
                      key={idx}
                      onClick={() => handleSelectNote(note)}
                      className="w-full bg-gray-900/50 hover:bg-gray-800/50 border border-gray-700 hover:border-privacy-500 rounded-lg p-4 text-left transition-colors"
                    >
                      <div className="flex justify-between items-center">
                        <div>
                          <div className="font-semibold">
                            {(note.amount / LAMPORTS_PER_SOL).toFixed(4)} SOL
                          </div>
                          <div className="text-sm text-gray-400">
                            Deposited {new Date(note.timestamp).toLocaleDateString()}
                          </div>
                        </div>
                        <div className="text-privacy-400">→</div>
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            )}

            {/* Import Note */}
            <div>
              <h3 className="text-lg font-semibold mb-3">
                {notes.length > 0 ? 'Or Import a Note' : 'Import Your Note'}
              </h3>
              <textarea
                value={importedNote}
                onChange={(e) => setImportedNote(e.target.value)}
                placeholder="Paste your encoded note here..."
                className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-3 font-mono text-sm h-32 focus:outline-none focus:border-privacy-500"
              />
              <button
                onClick={handleImportNote}
                disabled={!importedNote.trim()}
                className="w-full mt-3 py-3 bg-gray-800 hover:bg-gray-700 disabled:bg-gray-800/50 disabled:cursor-not-allowed rounded-lg font-medium transition-colors"
              >
                Import & Continue
              </button>
            </div>

            {/* Error Message */}
            {error && (
              <div className="bg-red-900/30 border border-red-700/50 rounded-lg p-4 text-red-200">
                {error}
              </div>
            )}

            {/* No Notes Warning */}
            {notes.length === 0 && (
              <div className="bg-yellow-900/30 border border-yellow-700/50 rounded-lg p-4">
                <div className="flex gap-3">
                  <span className="text-xl">💡</span>
                  <div>
                    <div className="font-semibold text-yellow-200">No saved notes</div>
                    <div className="text-sm text-yellow-200/80">
                      If you made a deposit, paste your note above to withdraw. 
                      Notes are also saved in browser storage after each deposit.
                    </div>
                  </div>
                </div>
              </div>
            )}
          </div>
        )}

        {step === 'input' && selectedNote && (
          <div className="space-y-6">
            {/* Selected Note Info */}
            <div className="bg-privacy-900/30 border border-privacy-700/50 rounded-lg p-4">
              <div className="flex justify-between items-center">
                <div>
                  <div className="text-sm text-gray-400">Amount to Withdraw</div>
                  <div className="text-2xl font-bold text-privacy-400">
                    {(selectedNote.amount / LAMPORTS_PER_SOL).toFixed(4)} SOL
                  </div>
                </div>
                <button
                  onClick={() => {
                    setSelectedNote(null);
                    setStep('select');
                  }}
                  className="text-sm text-gray-400 hover:text-white"
                >
                  Change
                </button>
              </div>
            </div>

            {/* Recipient */}
            <div>
              <label className="block text-sm font-medium mb-2">Recipient Address</label>
              <input
                type="text"
                value={recipient}
                onChange={(e) => setRecipient(e.target.value)}
                placeholder="Enter Solana address..."
                className="w-full bg-gray-900 border border-gray-700 rounded-lg px-4 py-3 font-mono text-sm focus:outline-none focus:border-privacy-500"
              />
              <p className="text-sm text-gray-500 mt-2">
                💡 You can withdraw to ANY address. It doesn't need to be connected!
              </p>
            </div>

            {/* Privacy Info */}
            <div className="bg-green-900/30 border border-green-700/50 rounded-lg p-4">
              <div className="flex gap-3">
                <span className="text-xl">🔒</span>
                <div>
                  <div className="font-semibold text-green-200">Anonymous Withdrawal</div>
                  <div className="text-sm text-green-200/80">
                    ZK proof ensures NO on-chain link between your deposit and this withdrawal. 
                    The recipient could be anyone who deposited to the pool.
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

            {/* Withdraw Button */}
            <button
              onClick={handleWithdraw}
              disabled={!connected || !recipient}
              className="w-full py-4 bg-privacy-600 hover:bg-privacy-700 disabled:bg-gray-700 disabled:cursor-not-allowed rounded-lg font-semibold text-lg transition-colors"
            >
              {connected ? 'Withdraw Anonymously' : 'Connect Wallet First'}
            </button>
          </div>
        )}

        {step === 'generating' && (
          <div className="text-center py-12">
            <div className="animate-spin w-16 h-16 border-4 border-privacy-500 border-t-transparent rounded-full mx-auto mb-6"></div>
            <h2 className="text-2xl font-semibold mb-2">Generating ZK Proof</h2>
            <p className="text-gray-400">Rebuilding Merkle tree and generating proof...</p>
            <p className="text-sm text-gray-500 mt-2">This may take 30-60 seconds</p>
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

        {step === 'success' && selectedNote && (
          <div className="space-y-6">
            <div className="bg-green-900/30 border border-green-700/50 rounded-lg p-6 text-center">
              <div className="text-4xl mb-4">🎉</div>
              <h2 className="text-2xl font-semibold mb-2">Withdrawal Successful!</h2>
              <p className="text-gray-400 mb-2">
                {(selectedNote.amount / LAMPORTS_PER_SOL).toFixed(4)} SOL sent anonymously to:
              </p>
              <p className="font-mono text-sm text-privacy-400 break-all">{recipient}</p>
              <a
                href={`https://explorer.solana.com/tx/${signature}?cluster=testnet`}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-block mt-4 text-privacy-400 hover:underline text-sm"
              >
                View on Explorer →
              </a>
            </div>

            <div className="bg-gray-900/50 rounded-lg p-6 border border-gray-800">
              <h3 className="font-semibold mb-3">🔐 Privacy Achieved</h3>
              <ul className="space-y-2 text-gray-400 text-sm">
                <li>✓ No link between your deposit and this withdrawal on-chain</li>
                <li>✓ Your note has been removed from local storage</li>
                <li>✓ Recipient address has no traceable connection to the depositor</li>
                <li>✓ Transaction could have come from any of {poolStats?.totalDeposits || 'many'} depositors</li>
              </ul>
            </div>

            <button
              onClick={() => {
                setStep('select');
                setSelectedNote(null);
                setSignature('');
              }}
              className="w-full py-3 bg-gray-800 hover:bg-gray-700 rounded-lg font-medium transition-colors"
            >
              Make Another Withdrawal
            </button>
          </div>
        )}

        {step === 'error' && (
          <div className="space-y-6">
            <div className="bg-red-900/30 border border-red-700/50 rounded-lg p-6 text-center">
              <div className="text-4xl mb-4">❌</div>
              <h2 className="text-2xl font-semibold mb-2">Withdrawal Failed</h2>
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
