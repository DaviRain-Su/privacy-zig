'use client';

import { useState, useEffect, useCallback } from 'react';
import { Header } from '@/components/Header';
import { 
  getNotesFromStorage, 
  removeNoteFromStorage, 
  serializeDepositNote,
  DepositNote 
} from '@/lib/privacy';
import Link from 'next/link';

export default function NotesPage() {
  const [notes, setNotes] = useState<DepositNote[]>([]);
  const [selectedNote, setSelectedNote] = useState<DepositNote | null>(null);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    setNotes(getNotesFromStorage());
  }, []);

  const formatAmount = (lamports: string) => {
    return (Number(lamports) / 1e9).toFixed(4);
  };

  const formatDate = (timestamp: number) => {
    return new Date(timestamp).toLocaleString();
  };

  const handleCopyNote = useCallback((note: DepositNote) => {
    const serialized = serializeDepositNote(note);
    navigator.clipboard.writeText(serialized);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }, []);

  const handleDeleteNote = useCallback((commitment: string) => {
    if (confirm('Are you sure? If you haven\'t withdrawn, you will lose access to these funds!')) {
      removeNoteFromStorage(commitment);
      setNotes(getNotesFromStorage());
      setSelectedNote(null);
    }
  }, []);

  const totalBalance = notes.reduce((sum, note) => sum + Number(note.amount), 0);

  return (
    <main className="min-h-screen">
      <Header />
      
      <div className="max-w-4xl mx-auto px-4 py-12">
        <div className="flex items-center justify-between mb-8">
          <div>
            <h1 className="text-3xl font-bold">My Notes</h1>
            <p className="text-gray-400">Manage your deposit notes</p>
          </div>
          <div className="text-right">
            <div className="text-sm text-gray-400">Total Balance</div>
            <div className="text-2xl font-bold text-privacy-400">
              {(totalBalance / 1e9).toFixed(4)} SOL
            </div>
          </div>
        </div>

        {notes.length === 0 ? (
          <div className="bg-gray-900/50 rounded-xl p-12 border border-gray-800 text-center">
            <div className="text-6xl mb-4">📝</div>
            <h2 className="text-xl font-semibold mb-2">No Notes Found</h2>
            <p className="text-gray-400 mb-6">
              You don't have any deposit notes saved in this browser.
            </p>
            <Link
              href="/deposit"
              className="inline-block px-6 py-3 bg-privacy-600 hover:bg-privacy-700 rounded-lg font-medium transition-colors"
            >
              Make Your First Deposit
            </Link>
          </div>
        ) : (
          <div className="grid md:grid-cols-2 gap-6">
            {/* Notes List */}
            <div className="space-y-4">
              <h2 className="text-lg font-semibold text-gray-300">Your Notes</h2>
              {notes.map((note) => (
                <div
                  key={note.commitment}
                  onClick={() => setSelectedNote(note)}
                  className={`p-4 rounded-xl border cursor-pointer transition-all ${
                    selectedNote?.commitment === note.commitment
                      ? 'bg-privacy-900/30 border-privacy-600'
                      : 'bg-gray-900/50 border-gray-800 hover:border-gray-600'
                  }`}
                >
                  <div className="flex items-center justify-between mb-2">
                    <span className="text-xl font-bold">
                      {formatAmount(note.amount)} SOL
                    </span>
                    <span className={`px-2 py-1 rounded text-xs ${
                      note.leafIndex >= 0 
                        ? 'bg-green-900/50 text-green-400' 
                        : 'bg-yellow-900/50 text-yellow-400'
                    }`}>
                      {note.leafIndex >= 0 ? 'Confirmed' : 'Pending'}
                    </span>
                  </div>
                  <div className="text-sm text-gray-400">
                    {formatDate(note.timestamp)}
                  </div>
                  <div className="text-xs text-gray-500 font-mono mt-1">
                    {note.commitment.slice(0, 24)}...
                  </div>
                </div>
              ))}
            </div>

            {/* Note Details */}
            <div>
              <h2 className="text-lg font-semibold text-gray-300 mb-4">Note Details</h2>
              {selectedNote ? (
                <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
                  <div className="space-y-4">
                    <div>
                      <div className="text-sm text-gray-400">Amount</div>
                      <div className="text-2xl font-bold">
                        {formatAmount(selectedNote.amount)} SOL
                      </div>
                    </div>
                    
                    <div>
                      <div className="text-sm text-gray-400">Deposited</div>
                      <div>{formatDate(selectedNote.timestamp)}</div>
                    </div>
                    
                    <div>
                      <div className="text-sm text-gray-400">Leaf Index</div>
                      <div className="font-mono">
                        {selectedNote.leafIndex >= 0 ? selectedNote.leafIndex : 'Pending...'}
                      </div>
                    </div>
                    
                    <div>
                      <div className="text-sm text-gray-400">Commitment</div>
                      <div className="font-mono text-xs break-all bg-gray-800 p-2 rounded">
                        {selectedNote.commitment}
                      </div>
                    </div>
                  </div>

                  <div className="mt-6 space-y-3">
                    <button
                      onClick={() => handleCopyNote(selectedNote)}
                      className="w-full py-3 bg-gray-700 hover:bg-gray-600 rounded-lg font-medium transition-colors"
                    >
                      {copied ? '✓ Copied!' : '📋 Copy Note'}
                    </button>
                    
                    <Link
                      href="/withdraw"
                      className="block w-full py-3 bg-privacy-600 hover:bg-privacy-700 rounded-lg font-medium text-center transition-colors"
                    >
                      💸 Withdraw This Note
                    </Link>
                    
                    <button
                      onClick={() => handleDeleteNote(selectedNote.commitment)}
                      className="w-full py-3 bg-red-900/30 hover:bg-red-900/50 border border-red-800 text-red-400 rounded-lg font-medium transition-colors"
                    >
                      🗑️ Delete Note
                    </button>
                  </div>
                  
                  <div className="mt-4 p-3 bg-yellow-900/20 border border-yellow-800/50 rounded-lg">
                    <p className="text-yellow-500 text-xs">
                      ⚠️ Deleting a note without withdrawing first will result in permanent loss of funds!
                    </p>
                  </div>
                </div>
              ) : (
                <div className="bg-gray-900/50 rounded-xl p-12 border border-gray-800 text-center text-gray-500">
                  Select a note to view details
                </div>
              )}
            </div>
          </div>
        )}

        {/* Import Note */}
        {notes.length > 0 && (
          <div className="mt-8 p-4 bg-gray-900/50 rounded-xl border border-gray-800">
            <h3 className="font-medium mb-2">Import a Note</h3>
            <p className="text-sm text-gray-400 mb-3">
              Have a note from another device? Go to the withdraw page and paste it there.
            </p>
            <Link
              href="/withdraw"
              className="text-privacy-400 hover:underline text-sm"
            >
              Go to Withdraw →
            </Link>
          </div>
        )}
      </div>
    </main>
  );
}
