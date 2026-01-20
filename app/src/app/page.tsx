'use client';

import { useState, useEffect } from 'react';
import { useConnection } from '@solana/wallet-adapter-react';
import dynamic from 'next/dynamic';
import Link from 'next/link';
import { getPoolStats } from '@/lib/privacy';
import { getNotes, getWithdrawableNotes } from '@/lib/notes';

const WalletMultiButton = dynamic(
  () => import('@solana/wallet-adapter-react-ui').then(mod => mod.WalletMultiButton),
  { ssr: false }
);

export default function Home() {
  const { connection } = useConnection();
  const [stats, setStats] = useState<{ totalDeposits: number; poolBalance: number } | null>(null);
  const [noteCount, setNoteCount] = useState({ total: 0, withdrawable: 0 });
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  useEffect(() => {
    if (mounted) {
      getPoolStats(connection).then(setStats).catch(console.error);
      setNoteCount({
        total: getNotes().length,
        withdrawable: getWithdrawableNotes().length,
      });
    }
  }, [connection, mounted]);

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
        <div className="max-w-4xl mx-auto flex justify-between items-center">
          <div className="flex items-center gap-2">
            <span className="text-2xl">🔒</span>
            <span className="font-bold text-xl text-purple-400">Privacy Pool</span>
          </div>
          <div className="flex items-center gap-4">
            <nav className="flex gap-4 text-sm">
              <Link href="/deposit" className="text-gray-400 hover:text-white">Deposit</Link>
              <Link href="/withdraw" className="text-gray-400 hover:text-white">Withdraw</Link>
              <Link href="/notes" className="text-gray-400 hover:text-white">Notes</Link>
            </nav>
            <WalletMultiButton className="!bg-purple-600 hover:!bg-purple-700" />
          </div>
        </div>
      </header>

      <div className="max-w-4xl mx-auto px-4 py-16">
        {/* Hero */}
        <div className="text-center mb-16">
          <h1 className="text-5xl font-bold mb-6">
            Private Transfers on <span className="text-purple-400">Solana</span>
          </h1>
          <p className="text-xl text-gray-400 max-w-2xl mx-auto">
            Send SOL privately using zero-knowledge proofs. 
            No on-chain link between deposits and withdrawals.
          </p>
        </div>

        {/* Backup Reminder */}
        {noteCount.withdrawable > 0 && (
          <div className="bg-yellow-900/30 border border-yellow-700/50 rounded-xl p-4 mb-8">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-3">
                <span className="text-2xl">⚠️</span>
                <div>
                  <p className="text-yellow-400 font-semibold">
                    You have {noteCount.withdrawable} note{noteCount.withdrawable > 1 ? 's' : ''} worth funds
                  </p>
                  <p className="text-sm text-yellow-300/70">
                    Make sure to backup your notes to avoid losing access
                  </p>
                </div>
              </div>
              <Link
                href="/notes"
                className="px-4 py-2 bg-yellow-600 hover:bg-yellow-700 rounded-lg text-sm font-semibold whitespace-nowrap"
              >
                Backup Now
              </Link>
            </div>
          </div>
        )}

        {/* Action Cards */}
        <div className="grid md:grid-cols-2 gap-6 mb-16">
          <Link 
            href="/deposit"
            className="bg-gradient-to-br from-purple-900/50 to-purple-800/30 rounded-2xl p-8 border border-purple-700/50 hover:border-purple-500 transition-colors group"
          >
            <div className="text-4xl mb-4">📥</div>
            <h2 className="text-2xl font-bold mb-2 group-hover:text-purple-400">Deposit</h2>
            <p className="text-gray-400">
              Deposit SOL to the privacy pool. A private note will be saved to your browser.
            </p>
          </Link>

          <Link 
            href="/withdraw"
            className="bg-gradient-to-br from-green-900/50 to-green-800/30 rounded-2xl p-8 border border-green-700/50 hover:border-green-500 transition-colors group"
          >
            <div className="text-4xl mb-4">📤</div>
            <h2 className="text-2xl font-bold mb-2 group-hover:text-green-400">Withdraw</h2>
            <p className="text-gray-400">
              Withdraw your funds to any address. The link to your deposit is broken.
            </p>
            {noteCount.withdrawable > 0 && (
              <div className="mt-4 inline-block px-3 py-1 bg-green-900/50 rounded-full text-sm text-green-400">
                {noteCount.withdrawable} note{noteCount.withdrawable > 1 ? 's' : ''} available
              </div>
            )}
          </Link>
        </div>

        {/* How it Works */}
        <div className="mb-16">
          <h2 className="text-2xl font-bold mb-8 text-center">How It Works</h2>
          <div className="grid md:grid-cols-3 gap-6">
            <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
              <div className="text-3xl mb-4">1️⃣</div>
              <h3 className="font-semibold mb-2">Deposit SOL</h3>
              <p className="text-sm text-gray-400">
                Deposit any amount. A ZK proof is generated and a private note is saved to your browser.
              </p>
            </div>
            <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
              <div className="text-3xl mb-4">2️⃣</div>
              <h3 className="font-semibold mb-2">Wait (Optional)</h3>
              <p className="text-sm text-gray-400">
                More deposits = more anonymity. Your funds mix with others in the pool.
              </p>
            </div>
            <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
              <div className="text-3xl mb-4">3️⃣</div>
              <h3 className="font-semibold mb-2">Withdraw Privately</h3>
              <p className="text-sm text-gray-400">
                Use your note to withdraw to any address. No link to your original deposit!
              </p>
            </div>
          </div>
        </div>

        {/* Pool Stats */}
        {stats && (
          <div className="bg-gray-900/30 rounded-2xl p-8 border border-gray-800">
            <h2 className="text-xl font-bold mb-6 text-center">Pool Statistics</h2>
            <div className="grid grid-cols-2 md:grid-cols-4 gap-6 text-center">
              <div>
                <div className="text-3xl font-bold text-purple-400">{stats.poolBalance.toFixed(2)}</div>
                <div className="text-sm text-gray-500">SOL in Pool</div>
              </div>
              <div>
                <div className="text-3xl font-bold">{stats.totalDeposits}</div>
                <div className="text-sm text-gray-500">Total Deposits</div>
              </div>
              <div>
                <div className="text-3xl font-bold text-green-400">{noteCount.withdrawable}</div>
                <div className="text-sm text-gray-500">Your Notes</div>
              </div>
              <div>
                <div className="text-3xl font-bold">Testnet</div>
                <div className="text-sm text-gray-500">Network</div>
              </div>
            </div>
          </div>
        )}

        {/* Tech Info */}
        <div className="mt-16 text-center text-sm text-gray-500">
          <p>Built with Zig + Solana + Groth16 ZK Proofs</p>
          <p className="mt-1">
            <a 
              href="https://github.com/example/privacy-zig" 
              className="text-purple-400 hover:underline"
              target="_blank"
              rel="noopener noreferrer"
            >
              View Source Code →
            </a>
          </p>
        </div>
      </div>
    </main>
  );
}
