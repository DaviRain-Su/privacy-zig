'use client';

import { useState, useEffect } from 'react';
import { LAMPORTS_PER_SOL } from '@solana/web3.js';
import { Header } from '@/components/Header';
import { 
  getNotesFromStorage, 
  removeNoteFromStorage,
  exportNote,
  importNote,
  saveNoteToStorage,
  DepositNote 
} from '@/lib/privacy';
import Link from 'next/link';

export default function NotesPage() {
  const [notes, setNotes] = useState<DepositNote[]>([]);
  const [importValue, setImportValue] = useState('');
  const [copiedIndex, setCopiedIndex] = useState<number | null>(null);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  useEffect(() => {
    setNotes(getNotesFromStorage());
  }, []);

  const handleCopy = (note: DepositNote, index: number) => {
    const encoded = exportNote(note);
    navigator.clipboard.writeText(encoded);
    setCopiedIndex(index);
    setTimeout(() => setCopiedIndex(null), 2000);
  };

  const handleDownload = (note: DepositNote) => {
    const blob = new Blob([JSON.stringify(note, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `privacy-note-${note.timestamp}.json`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const handleDelete = (commitment: string) => {
    if (confirm('Are you sure? You will LOSE access to these funds if you don\'t have a backup!')) {
      removeNoteFromStorage(commitment);
      setNotes(getNotesFromStorage());
    }
  };

  const handleImport = () => {
    setError('');
    setSuccess('');
    
    try {
      const note = importNote(importValue);
      
      // Check if already exists
      const existing = notes.find(n => n.commitment === note.commitment);
      if (existing) {
        setError('This note already exists in your storage');
        return;
      }
      
      saveNoteToStorage(note);
      setNotes(getNotesFromStorage());
      setImportValue('');
      setSuccess('Note imported successfully!');
      setTimeout(() => setSuccess(''), 3000);
    } catch (e) {
      setError('Invalid note format. Please check and try again.');
    }
  };

  const handleFileImport = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    
    const reader = new FileReader();
    reader.onload = (event) => {
      try {
        const note = JSON.parse(event.target?.result as string) as DepositNote;
        
        // Validate note structure
        if (!note.commitment || !note.privkey || !note.amount) {
          setError('Invalid note file format');
          return;
        }
        
        const existing = notes.find(n => n.commitment === note.commitment);
        if (existing) {
          setError('This note already exists in your storage');
          return;
        }
        
        saveNoteToStorage(note);
        setNotes(getNotesFromStorage());
        setSuccess('Note imported successfully!');
        setTimeout(() => setSuccess(''), 3000);
      } catch (e) {
        setError('Failed to parse note file');
      }
    };
    reader.readAsText(file);
    
    // Reset input
    e.target.value = '';
  };

  const totalValue = notes.reduce((sum, n) => sum + n.amount, 0) / LAMPORTS_PER_SOL;

  return (
    <main className="min-h-screen">
      <Header />
      
      <div className="max-w-3xl mx-auto px-4 py-12">
        <h1 className="text-4xl font-bold mb-2">Your Notes</h1>
        <p className="text-gray-400 mb-8">
          Manage your deposit notes. Each note represents funds you can withdraw.
        </p>

        {/* Summary */}
        <div className="bg-gradient-to-r from-privacy-900/50 to-gray-900/50 rounded-xl p-6 mb-8 border border-privacy-800/50">
          <div className="flex justify-between items-center">
            <div>
              <div className="text-sm text-gray-400">Total Available</div>
              <div className="text-3xl font-bold text-privacy-400">
                {totalValue.toFixed(4)} SOL
              </div>
            </div>
            <div className="text-right">
              <div className="text-sm text-gray-400">Notes</div>
              <div className="text-3xl font-bold">{notes.length}</div>
            </div>
          </div>
        </div>

        {/* Import Section */}
        <div className="bg-gray-900/50 rounded-xl p-6 mb-8 border border-gray-800">
          <h2 className="text-lg font-semibold mb-4">Import Note</h2>
          
          <div className="space-y-4">
            {/* Paste import */}
            <div>
              <textarea
                value={importValue}
                onChange={(e) => setImportValue(e.target.value)}
                placeholder="Paste encoded note here..."
                className="w-full bg-gray-800 border border-gray-700 rounded-lg px-4 py-3 font-mono text-sm h-24 focus:outline-none focus:border-privacy-500"
              />
              <button
                onClick={handleImport}
                disabled={!importValue.trim()}
                className="mt-2 px-4 py-2 bg-privacy-600 hover:bg-privacy-700 disabled:bg-gray-700 disabled:cursor-not-allowed rounded-lg text-sm font-medium transition-colors"
              >
                Import from Text
              </button>
            </div>
            
            {/* File import */}
            <div className="flex items-center gap-4 pt-2 border-t border-gray-800">
              <span className="text-sm text-gray-400">Or import from file:</span>
              <label className="px-4 py-2 bg-gray-800 hover:bg-gray-700 rounded-lg text-sm font-medium cursor-pointer transition-colors">
                📁 Choose File
                <input
                  type="file"
                  accept=".json"
                  onChange={handleFileImport}
                  className="hidden"
                />
              </label>
            </div>
          </div>

          {/* Messages */}
          {error && (
            <div className="mt-4 p-3 bg-red-900/30 border border-red-700/50 rounded-lg text-red-200 text-sm">
              {error}
            </div>
          )}
          {success && (
            <div className="mt-4 p-3 bg-green-900/30 border border-green-700/50 rounded-lg text-green-200 text-sm">
              {success}
            </div>
          )}
        </div>

        {/* Notes List */}
        {notes.length > 0 ? (
          <div className="space-y-4">
            <h2 className="text-lg font-semibold">Saved Notes</h2>
            
            {notes.map((note, idx) => (
              <div
                key={note.commitment}
                className="bg-gray-900/50 rounded-xl p-5 border border-gray-800 hover:border-gray-700 transition-colors"
              >
                <div className="flex justify-between items-start mb-4">
                  <div>
                    <div className="text-2xl font-bold text-privacy-400">
                      {(note.amount / LAMPORTS_PER_SOL).toFixed(4)} SOL
                    </div>
                    <div className="text-sm text-gray-400">
                      Deposited {new Date(note.timestamp).toLocaleString()}
                    </div>
                    <div className="text-xs text-gray-500 font-mono mt-1">
                      Leaf #{note.leafIndex}
                    </div>
                  </div>
                  <Link
                    href="/withdraw"
                    className="px-4 py-2 bg-privacy-600 hover:bg-privacy-700 rounded-lg text-sm font-medium transition-colors"
                  >
                    Withdraw →
                  </Link>
                </div>

                <div className="flex gap-2 pt-4 border-t border-gray-800">
                  <button
                    onClick={() => handleCopy(note, idx)}
                    className="px-3 py-1.5 bg-gray-800 hover:bg-gray-700 rounded text-sm transition-colors"
                  >
                    {copiedIndex === idx ? '✓ Copied' : '📋 Copy'}
                  </button>
                  <button
                    onClick={() => handleDownload(note)}
                    className="px-3 py-1.5 bg-gray-800 hover:bg-gray-700 rounded text-sm transition-colors"
                  >
                    💾 Download
                  </button>
                  <button
                    onClick={() => handleDelete(note.commitment)}
                    className="px-3 py-1.5 bg-red-900/30 hover:bg-red-900/50 text-red-400 rounded text-sm transition-colors ml-auto"
                  >
                    🗑️ Delete
                  </button>
                </div>
              </div>
            ))}
          </div>
        ) : (
          <div className="text-center py-12 bg-gray-900/30 rounded-xl border border-gray-800">
            <div className="text-4xl mb-4">📭</div>
            <h3 className="text-xl font-semibold mb-2">No Notes Yet</h3>
            <p className="text-gray-400 mb-6">
              Deposit SOL to receive your first note, or import an existing one.
            </p>
            <Link
              href="/deposit"
              className="inline-block px-6 py-3 bg-privacy-600 hover:bg-privacy-700 rounded-lg font-medium transition-colors"
            >
              Make a Deposit
            </Link>
          </div>
        )}

        {/* Security Notice */}
        <div className="mt-8 bg-yellow-900/30 border border-yellow-700/50 rounded-lg p-4">
          <div className="flex gap-3">
            <span className="text-xl">⚠️</span>
            <div>
              <div className="font-semibold text-yellow-200">Security Reminder</div>
              <div className="text-sm text-yellow-200/80">
                Notes are stored in your browser's local storage. Always keep backup copies!
                If you clear browser data or use a different device, you'll need your backups 
                to access your funds.
              </div>
            </div>
          </div>
        </div>
      </div>
    </main>
  );
}
