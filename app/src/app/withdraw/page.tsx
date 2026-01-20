'use client';

import { useState, useCallback } from 'react';
import { useWallet, useConnection } from '@solana/wallet-adapter-react';
import { Header } from '@/components/Header';
import { parseDepositNote, DepositNote } from '@/lib/privacy';

export default function WithdrawPage() {
  const { publicKey, connected } = useWallet();
  const { connection } = useConnection();
  
  const [noteInput, setNoteInput] = useState('');
  const [recipientAddress, setRecipientAddress] = useState('');
  const [parsedNote, setParsedNote] = useState<DepositNote | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [isGeneratingProof, setIsGeneratingProof] = useState(false);
  const [success, setSuccess] = useState(false);
  const [txSignature, setTxSignature] = useState('');
  const [error, setError] = useState('');

  const handleParseNote = useCallback(() => {
    try {
      const note = parseDepositNote(noteInput.trim());
      setParsedNote(note);
      setError('');
    } catch (err) {
      setError('Invalid note format. Please check and try again.');
      setParsedNote(null);
    }
  }, [noteInput]);

  const handleWithdraw = useCallback(async () => {
    if (!parsedNote) {
      setError('Please enter a valid note first');
      return;
    }

    if (!recipientAddress) {
      setError('Please enter a recipient address');
      return;
    }

    setIsLoading(true);
    setIsGeneratingProof(true);
    setError('');

    try {
      // Step 1: Generate ZK proof (this would use snarkjs in production)
      await new Promise(resolve => setTimeout(resolve, 2000)); // Simulate proof generation
      setIsGeneratingProof(false);

      // Step 2: Build and send transaction
      // In production, this would:
      // 1. Rebuild Merkle tree from on-chain events
      // 2. Get Merkle proof for the commitment
      // 3. Generate Groth16 proof using snarkjs
      // 4. Build transact instruction with publicAmount < 0
      // 5. Send and confirm transaction

      await new Promise(resolve => setTimeout(resolve, 1000)); // Simulate tx

      // Simulate success
      setTxSignature('5xYz...demo...signature');
      setSuccess(true);
      
    } catch (err: any) {
      setError(err.message || 'Withdrawal failed');
    } finally {
      setIsLoading(false);
      setIsGeneratingProof(false);
    }
  }, [parsedNote, recipientAddress]);

  const formatAmount = (lamports: string) => {
    return (Number(lamports) / 1e9).toFixed(4);
  };

  return (
    <main className="min-h-screen">
      <Header />
      
      <div className="max-w-2xl mx-auto px-4 py-12">
        <h1 className="text-3xl font-bold mb-2">Withdraw SOL</h1>
        <p className="text-gray-400 mb-8">
          Use your secret note to withdraw to any address. 
          The ZK proof ensures no connection to the original deposit.
        </p>

        {!success ? (
          <div className="space-y-6">
            {/* Note Input */}
            <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
              <label className="block text-sm font-medium mb-2">
                🔑 Secret Note
              </label>
              <textarea
                value={noteInput}
                onChange={(e) => setNoteInput(e.target.value)}
                placeholder="Paste your secret note here..."
                className="w-full h-32 bg-gray-800 rounded-lg px-4 py-3 font-mono text-sm focus:outline-none focus:ring-2 focus:ring-privacy-500 resize-none"
              />
              <button
                onClick={handleParseNote}
                className="mt-3 px-6 py-2 bg-gray-700 hover:bg-gray-600 rounded-lg text-sm font-medium transition-colors"
              >
                Parse Note
              </button>
            </div>

            {/* Parsed Note Info */}
            {parsedNote && (
              <div className="bg-privacy-900/30 rounded-xl p-6 border border-privacy-800">
                <h3 className="font-semibold mb-4 text-privacy-400">✓ Note Verified</h3>
                <div className="space-y-2 text-sm">
                  <div className="flex justify-between">
                    <span className="text-gray-400">Amount:</span>
                    <span className="font-mono">{formatAmount(parsedNote.amount)} SOL</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-400">Commitment:</span>
                    <span className="font-mono text-xs">
                      {parsedNote.commitment.slice(0, 16)}...
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-400">Deposited:</span>
                    <span>{new Date(parsedNote.timestamp).toLocaleString()}</span>
                  </div>
                </div>
              </div>
            )}

            {/* Recipient Address */}
            <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
              <label className="block text-sm font-medium mb-2">
                📬 Recipient Address
              </label>
              <input
                type="text"
                value={recipientAddress}
                onChange={(e) => setRecipientAddress(e.target.value)}
                placeholder="Enter Solana address..."
                className="w-full bg-gray-800 rounded-lg px-4 py-3 font-mono text-sm focus:outline-none focus:ring-2 focus:ring-privacy-500"
              />
              <p className="text-sm text-gray-500 mt-2">
                This can be any address - including a fresh wallet with no history.
              </p>
            </div>

            {/* Error */}
            {error && (
              <div className="p-4 bg-red-900/30 border border-red-800 rounded-lg text-red-400">
                {error}
              </div>
            )}

            {/* Withdraw Button */}
            <button
              onClick={handleWithdraw}
              disabled={!parsedNote || !recipientAddress || isLoading}
              className={`w-full py-4 rounded-lg font-semibold text-lg transition-colors ${
                parsedNote && recipientAddress && !isLoading
                  ? 'bg-privacy-600 hover:bg-privacy-700 text-white'
                  : 'bg-gray-700 text-gray-500 cursor-not-allowed'
              }`}
            >
              {isLoading 
                ? isGeneratingProof 
                  ? '🔐 Generating ZK Proof...' 
                  : '⏳ Sending Transaction...'
                : `Withdraw ${parsedNote ? formatAmount(parsedNote.amount) : '0'} SOL`
              }
            </button>

            {/* Privacy Info */}
            <div className="p-4 bg-gray-800/50 rounded-lg border border-gray-700">
              <h4 className="font-medium mb-2">🛡️ Privacy Guarantee</h4>
              <ul className="text-sm text-gray-400 space-y-1">
                <li>• ZK proof reveals nothing about the original deposit</li>
                <li>• Recipient address has no on-chain link to depositor</li>
                <li>• Only the nullifier is published (prevents double-spend)</li>
              </ul>
            </div>
          </div>
        ) : (
          /* Success State */
          <div className="bg-gray-900/50 rounded-xl p-6 border border-privacy-800 text-center">
            <div className="text-6xl mb-4">🎉</div>
            <h2 className="text-2xl font-bold text-privacy-400 mb-2">
              Withdrawal Successful!
            </h2>
            <p className="text-gray-400 mb-6">
              {formatAmount(parsedNote!.amount)} SOL sent to {recipientAddress.slice(0, 8)}...
            </p>

            <div className="bg-gray-800 rounded-lg p-4 mb-6">
              <div className="text-sm text-gray-400 mb-1">Transaction:</div>
              <a
                href={`https://explorer.solana.com/tx/${txSignature}?cluster=devnet`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-privacy-400 hover:underline font-mono text-sm"
              >
                {txSignature}
              </a>
            </div>

            <div className="bg-privacy-900/30 rounded-lg p-4 border border-privacy-800">
              <p className="text-privacy-400 text-sm">
                ✓ The transaction graph has been broken! 
                There is no on-chain link between the depositor and recipient.
              </p>
            </div>

            <button
              onClick={() => {
                setSuccess(false);
                setNoteInput('');
                setRecipientAddress('');
                setParsedNote(null);
              }}
              className="mt-6 px-6 py-3 bg-gray-700 hover:bg-gray-600 rounded-lg font-medium transition-colors"
            >
              Make Another Withdrawal
            </button>
          </div>
        )}
      </div>
    </main>
  );
}
