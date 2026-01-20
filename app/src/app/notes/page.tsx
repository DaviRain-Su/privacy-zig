'use client';

import { useState, useEffect } from 'react';
import dynamic from 'next/dynamic';
import Link from 'next/link';
import { 
  getNotes, 
  deleteNote, 
  exportNotes, 
  importNotes, 
  formatAmount, 
  formatDate,
  Note 
} from '@/lib/notes';

const WalletMultiButton = dynamic(
  () => import('@solana/wallet-adapter-react-ui').then(mod => mod.WalletMultiButton),
  { ssr: false }
);

export default function NotesPage() {
  const [notes, setNotes] = useState<Note[]>([]);
  const [showExport, setShowExport] = useState(false);
  const [showImport, setShowImport] = useState(false);
  const [importData, setImportData] = useState('');
  const [importResult, setImportResult] = useState<string | null>(null);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  useEffect(() => {
    if (mounted) {
      setNotes(getNotes());
    }
  }, [mounted]);

  const handleDelete = (id: string) => {
    if (confirm('Are you sure you want to delete this note? You will lose access to these funds!')) {
      deleteNote(id);
      setNotes(getNotes());
    }
  };

  const handleExport = () => {
    const data = exportNotes();
    navigator.clipboard.writeText(data);
    alert('Notes copied to clipboard! Save this somewhere safe.');
  };

  const handleImport = () => {
    const count = importNotes(importData);
    setImportResult(`Imported ${count} new note(s)`);
    setNotes(getNotes());
    setImportData('');
    setTimeout(() => {
      setShowImport(false);
      setImportResult(null);
    }, 2000);
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'deposited': return 'text-green-400';
      case 'withdrawn': return 'text-gray-500';
      case 'pending': return 'text-yellow-400';
      default: return 'text-gray-400';
    }
  };

  const getStatusBadge = (status: string) => {
    switch (status) {
      case 'deposited': return 'bg-green-900/50 text-green-400';
      case 'withdrawn': return 'bg-gray-800 text-gray-500';
      case 'pending': return 'bg-yellow-900/50 text-yellow-400';
      default: return 'bg-gray-800 text-gray-400';
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
              <Link href="/deposit" className="text-gray-400 hover:text-white">Deposit</Link>
              <Link href="/withdraw" className="text-gray-400 hover:text-white">Withdraw</Link>
              <Link href="/notes" className="text-purple-400">Notes</Link>
            </nav>
            <WalletMultiButton className="!bg-purple-600 hover:!bg-purple-700" />
          </div>
        </div>
      </header>

      <div className="max-w-2xl mx-auto px-4 py-12">
        <div className="flex justify-between items-center mb-8">
          <div>
            <h1 className="text-3xl font-bold mb-2">My Notes</h1>
            <p className="text-gray-400">
              Your private deposit notes stored in this browser
            </p>
          </div>
          <div className="flex gap-2">
            <button
              onClick={() => setShowImport(!showImport)}
              className="px-4 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg text-sm"
            >
              Import
            </button>
            <button
              onClick={handleExport}
              className="px-4 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg text-sm"
            >
              Export
            </button>
          </div>
        </div>

        {/* Import Panel */}
        {showImport && (
          <div className="bg-gray-900/50 rounded-xl p-4 border border-gray-800 mb-6">
            <label className="block text-sm text-gray-400 mb-2">Paste exported notes data:</label>
            <textarea
              value={importData}
              onChange={(e) => setImportData(e.target.value)}
              className="w-full bg-black border border-gray-700 rounded-lg px-3 py-2 text-sm font-mono h-24 focus:outline-none focus:border-purple-500"
              placeholder="Paste your backup data here..."
            />
            <div className="flex justify-between items-center mt-2">
              <span className="text-sm text-gray-500">
                {importResult || 'Import notes from another browser or backup'}
              </span>
              <button
                onClick={handleImport}
                disabled={!importData}
                className="px-4 py-1 bg-purple-600 hover:bg-purple-700 disabled:bg-gray-700 rounded text-sm"
              >
                Import
              </button>
            </div>
          </div>
        )}

        {/* Warning */}
        <div className="bg-yellow-900/20 border border-yellow-800/50 rounded-lg p-4 mb-6 text-sm text-yellow-300">
          <p>⚠️ <strong>Important:</strong> Notes are stored only in your browser.</p>
          <p className="mt-1">Clearing browser data will delete them. Use Export to backup!</p>
        </div>

        {/* Notes List */}
        {notes.length === 0 ? (
          <div className="text-center py-16 text-gray-500">
            <p className="text-4xl mb-4">📝</p>
            <p>No notes yet.</p>
            <Link href="/deposit" className="text-purple-400 hover:underline mt-2 block">
              Make your first deposit →
            </Link>
          </div>
        ) : (
          <div className="space-y-4">
            {notes.map((note) => (
              <div
                key={note.id}
                className="bg-gray-900/50 rounded-xl p-4 border border-gray-800"
              >
                <div className="flex justify-between items-start">
                  <div>
                    <div className="flex items-center gap-3">
                      <span className="text-2xl font-mono">{formatAmount(note.amount)} SOL</span>
                      <span className={`px-2 py-0.5 rounded text-xs ${getStatusBadge(note.status)}`}>
                        {note.status}
                      </span>
                    </div>
                    <div className="text-xs text-gray-500 mt-2">
                      Created: {formatDate(note.createdAt)}
                    </div>
                  </div>
                  
                  <div className="flex gap-2">
                    {note.status === 'deposited' && (
                      <Link
                        href="/withdraw"
                        className="px-3 py-1 bg-purple-600 hover:bg-purple-700 rounded text-sm"
                      >
                        Withdraw
                      </Link>
                    )}
                    <button
                      onClick={() => handleDelete(note.id)}
                      className="px-3 py-1 bg-red-900/50 hover:bg-red-900 text-red-400 rounded text-sm"
                    >
                      Delete
                    </button>
                  </div>
                </div>

                {/* Transaction links */}
                <div className="mt-3 pt-3 border-t border-gray-800 flex gap-4 text-xs">
                  {note.depositTxSig && (
                    <a
                      href={`https://explorer.solana.com/tx/${note.depositTxSig}?cluster=testnet`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-purple-400 hover:underline"
                    >
                      Deposit TX →
                    </a>
                  )}
                  {note.withdrawTxSig && (
                    <a
                      href={`https://explorer.solana.com/tx/${note.withdrawTxSig}?cluster=testnet`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-purple-400 hover:underline"
                    >
                      Withdraw TX →
                    </a>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}

        {/* Summary */}
        {notes.length > 0 && (
          <div className="mt-8 p-4 bg-gray-900/30 rounded-lg text-center">
            <div className="flex justify-center gap-8 text-sm">
              <div>
                <div className="text-xl font-bold text-green-400">
                  {formatAmount(notes.filter(n => n.status === 'deposited').reduce((sum, n) => sum + n.amount, 0))}
                </div>
                <div className="text-gray-500">SOL Available</div>
              </div>
              <div>
                <div className="text-xl font-bold text-gray-500">
                  {formatAmount(notes.filter(n => n.status === 'withdrawn').reduce((sum, n) => sum + n.amount, 0))}
                </div>
                <div className="text-gray-500">SOL Withdrawn</div>
              </div>
              <div>
                <div className="text-xl font-bold">{notes.length}</div>
                <div className="text-gray-500">Total Notes</div>
              </div>
            </div>
          </div>
        )}
      </div>
    </main>
  );
}
