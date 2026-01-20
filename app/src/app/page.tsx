'use client';

import { useEffect, useState } from 'react';
import { useConnection } from '@solana/wallet-adapter-react';
import { Header } from '@/components/Header';
import Link from 'next/link';
import { getPoolStats } from '@/lib/privacy';

export default function Home() {
  const { connection } = useConnection();
  const [stats, setStats] = useState<{ totalDeposits: number; poolBalance: number } | null>(null);

  useEffect(() => {
    async function fetchStats() {
      try {
        const poolStats = await getPoolStats(connection);
        setStats(poolStats);
      } catch (e) {
        console.error('Failed to fetch stats:', e);
      }
    }
    fetchStats();
  }, [connection]);

  return (
    <main className="min-h-screen">
      <Header />
      
      {/* Hero Section */}
      <section className="max-w-6xl mx-auto px-4 py-20 text-center">
        <div className="inline-block px-4 py-1 bg-privacy-900/50 rounded-full text-privacy-400 text-sm font-medium mb-6 border border-privacy-800/50">
          🔐 Testnet Live
        </div>
        
        <h1 className="text-5xl md:text-6xl font-bold mb-6">
          <span className="text-white">Anonymous Transfer</span>
          <br />
          <span className="text-privacy-400">on Solana</span>
        </h1>
        
        <p className="text-xl text-gray-400 mb-10 max-w-2xl mx-auto">
          Break the transaction graph. Send SOL to new addresses 
          without revealing the connection between sender and recipient.
        </p>
        
        <div className="flex gap-4 justify-center flex-wrap">
          <Link
            href="/deposit"
            className="px-8 py-4 bg-privacy-600 hover:bg-privacy-700 rounded-lg font-semibold text-lg transition-colors"
          >
            Deposit SOL →
          </Link>
          <Link
            href="/withdraw"
            className="px-8 py-4 bg-gray-800 hover:bg-gray-700 rounded-lg font-semibold text-lg transition-colors"
          >
            Withdraw Anonymously
          </Link>
        </div>
      </section>

      {/* Live Stats */}
      {stats && (
        <section className="max-w-6xl mx-auto px-4 py-8">
          <div className="bg-gradient-to-r from-privacy-900/50 to-gray-900/50 rounded-2xl p-8 border border-privacy-800/50">
            <h2 className="text-center text-sm text-gray-400 mb-6 uppercase tracking-wider">
              Pool Statistics (Testnet)
            </h2>
            <div className="grid md:grid-cols-3 gap-8 text-center">
              <div>
                <div className="text-4xl font-bold text-privacy-400">
                  {stats.poolBalance.toFixed(2)} SOL
                </div>
                <div className="text-gray-400">Pool Balance</div>
              </div>
              <div>
                <div className="text-4xl font-bold text-white">
                  {stats.totalDeposits}
                </div>
                <div className="text-gray-400">Total Deposits</div>
              </div>
              <div>
                <div className="text-4xl font-bold text-green-400">
                  Active
                </div>
                <div className="text-gray-400">Pool Status</div>
              </div>
            </div>
          </div>
        </section>
      )}

      {/* How it works */}
      <section className="max-w-6xl mx-auto px-4 py-16">
        <h2 className="text-3xl font-bold text-center mb-12">How It Works</h2>
        
        <div className="grid md:grid-cols-3 gap-8">
          <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
            <div className="w-12 h-12 bg-privacy-600 rounded-lg flex items-center justify-center text-2xl mb-4">
              1
            </div>
            <h3 className="text-xl font-semibold mb-2">Deposit</h3>
            <p className="text-gray-400">
              Deposit SOL into the privacy pool. You'll receive a secret note - 
              keep it safe! This is your key to withdraw later.
            </p>
          </div>
          
          <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
            <div className="w-12 h-12 bg-privacy-600 rounded-lg flex items-center justify-center text-2xl mb-4">
              2
            </div>
            <h3 className="text-xl font-semibold mb-2">Mix</h3>
            <p className="text-gray-400">
              Your deposit joins others in the pool. The more activity, 
              the larger your anonymity set becomes.
            </p>
          </div>
          
          <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
            <div className="w-12 h-12 bg-privacy-600 rounded-lg flex items-center justify-center text-2xl mb-4">
              3
            </div>
            <h3 className="text-xl font-semibold mb-2">Withdraw</h3>
            <p className="text-gray-400">
              Use your secret note to withdraw to ANY address. 
              ZK proof ensures no link between deposit and withdrawal.
            </p>
          </div>
        </div>
      </section>

      {/* Privacy Explanation */}
      <section className="max-w-6xl mx-auto px-4 py-16">
        <div className="bg-gray-900/30 rounded-2xl p-8 border border-gray-800">
          <h2 className="text-2xl font-bold mb-6 text-center">Why It's Private</h2>
          
          <div className="grid md:grid-cols-2 gap-8">
            <div>
              <h3 className="text-lg font-semibold mb-3 text-red-400">❌ Normal Transfer</h3>
              <div className="bg-black/30 rounded-lg p-4 font-mono text-sm">
                <div className="text-gray-400">Alice → Bob</div>
                <div className="text-gray-500 text-xs mt-2">
                  Everyone can see Alice sent to Bob
                </div>
              </div>
            </div>
            
            <div>
              <h3 className="text-lg font-semibold mb-3 text-green-400">✓ Privacy Pool</h3>
              <div className="bg-black/30 rounded-lg p-4 font-mono text-sm">
                <div className="text-gray-400">Alice → Pool</div>
                <div className="text-gray-400">Carol → Pool</div>
                <div className="text-gray-400">Dave → Pool</div>
                <div className="text-gray-400">Pool → Bob (who deposited?)</div>
                <div className="text-gray-500 text-xs mt-2">
                  Bob's funds could be from Alice, Carol, or Dave!
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Technical Stats */}
      <section className="max-w-6xl mx-auto px-4 py-16">
        <h2 className="text-2xl font-bold text-center mb-8">Technical Specs</h2>
        <div className="grid md:grid-cols-4 gap-6">
          <div className="bg-gray-900/50 rounded-xl p-5 border border-gray-800 text-center">
            <div className="text-3xl font-bold text-privacy-400 mb-1">~30 KB</div>
            <div className="text-sm text-gray-400">Program Size</div>
          </div>
          <div className="bg-gray-900/50 rounded-xl p-5 border border-gray-800 text-center">
            <div className="text-3xl font-bold text-privacy-400 mb-1">~160K CU</div>
            <div className="text-sm text-gray-400">Per Transaction</div>
          </div>
          <div className="bg-gray-900/50 rounded-xl p-5 border border-gray-800 text-center">
            <div className="text-3xl font-bold text-privacy-400 mb-1">67M</div>
            <div className="text-sm text-gray-400">Max Deposits</div>
          </div>
          <div className="bg-gray-900/50 rounded-xl p-5 border border-gray-800 text-center">
            <div className="text-3xl font-bold text-privacy-400 mb-1">Groth16</div>
            <div className="text-sm text-gray-400">ZK System</div>
          </div>
        </div>
      </section>

      {/* CTA */}
      <section className="max-w-6xl mx-auto px-4 py-16 text-center">
        <h2 className="text-3xl font-bold mb-4">Ready to Try?</h2>
        <p className="text-gray-400 mb-8 max-w-xl mx-auto">
          The privacy pool is live on Solana Testnet. Get some test SOL and 
          experience anonymous transfers firsthand.
        </p>
        <div className="flex gap-4 justify-center flex-wrap">
          <Link
            href="/deposit"
            className="px-8 py-4 bg-privacy-600 hover:bg-privacy-700 rounded-lg font-semibold text-lg transition-colors"
          >
            Start Now →
          </Link>
          <a
            href="https://github.com/example/privacy-zig"
            target="_blank"
            rel="noopener noreferrer"
            className="px-8 py-4 bg-gray-800 hover:bg-gray-700 rounded-lg font-semibold text-lg transition-colors"
          >
            View Source
          </a>
        </div>
      </section>

      {/* Footer */}
      <footer className="max-w-6xl mx-auto px-4 py-8 text-center text-gray-500 border-t border-gray-800">
        <p className="mb-4">
          Built with 💜 using{' '}
          <a 
            href="https://ziglang.org" 
            target="_blank" 
            rel="noopener noreferrer"
            className="text-privacy-400 hover:underline"
          >
            Zig
          </a>
          {' '}+ anchor-zig framework
        </p>
        <p className="text-sm">
          Compatible with{' '}
          <a 
            href="https://github.com/Privacy-Cash/privacy-cash" 
            target="_blank" 
            rel="noopener noreferrer"
            className="text-privacy-400 hover:underline"
          >
            Privacy Cash
          </a>
          {' '}protocol
        </p>
      </footer>
    </main>
  );
}
