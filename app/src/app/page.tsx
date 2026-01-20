'use client';

import { Header } from '@/components/Header';
import Link from 'next/link';

export default function Home() {
  return (
    <main className="min-h-screen">
      <Header />
      
      {/* Hero Section */}
      <section className="max-w-6xl mx-auto px-4 py-20 text-center">
        <h1 className="text-5xl md:text-6xl font-bold mb-6">
          <span className="text-white">Anonymous Transfer</span>
          <br />
          <span className="text-privacy-400">on Solana</span>
        </h1>
        
        <p className="text-xl text-gray-400 mb-10 max-w-2xl mx-auto">
          Break the transaction graph. Send SOL to new addresses 
          without revealing the connection between sender and recipient.
        </p>
        
        <div className="flex gap-4 justify-center">
          <Link
            href="/deposit"
            className="px-8 py-4 bg-privacy-600 hover:bg-privacy-700 rounded-lg font-semibold text-lg transition-colors"
          >
            Start Deposit →
          </Link>
          <Link
            href="/withdraw"
            className="px-8 py-4 bg-gray-800 hover:bg-gray-700 rounded-lg font-semibold text-lg transition-colors"
          >
            Withdraw
          </Link>
        </div>
      </section>

      {/* How it works */}
      <section className="max-w-6xl mx-auto px-4 py-16">
        <h2 className="text-3xl font-bold text-center mb-12">How It Works</h2>
        
        <div className="grid md:grid-cols-3 gap-8">
          <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
            <div className="text-4xl mb-4">1️⃣</div>
            <h3 className="text-xl font-semibold mb-2">Deposit</h3>
            <p className="text-gray-400">
              Deposit SOL into the privacy pool. You'll receive a secret note - 
              keep it safe! This is your key to withdraw later.
            </p>
          </div>
          
          <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
            <div className="text-4xl mb-4">2️⃣</div>
            <h3 className="text-xl font-semibold mb-2">Wait</h3>
            <p className="text-gray-400">
              Other users deposit and withdraw. The more activity in the pool, 
              the stronger your privacy becomes.
            </p>
          </div>
          
          <div className="bg-gray-900/50 rounded-xl p-6 border border-gray-800">
            <div className="text-4xl mb-4">3️⃣</div>
            <h3 className="text-xl font-semibold mb-2">Withdraw</h3>
            <p className="text-gray-400">
              Use your secret note to withdraw to any new address. 
              ZK proof ensures no link between deposit and withdrawal.
            </p>
          </div>
        </div>
      </section>

      {/* Stats */}
      <section className="max-w-6xl mx-auto px-4 py-16">
        <div className="bg-gradient-to-r from-privacy-900/50 to-gray-900/50 rounded-2xl p-8 border border-privacy-800/50">
          <div className="grid md:grid-cols-4 gap-8 text-center">
            <div>
              <div className="text-4xl font-bold text-privacy-400">27 KB</div>
              <div className="text-gray-400">Program Size</div>
            </div>
            <div>
              <div className="text-4xl font-bold text-privacy-400">~5 CU</div>
              <div className="text-gray-400">Overhead</div>
            </div>
            <div>
              <div className="text-4xl font-bold text-privacy-400">67M</div>
              <div className="text-gray-400">Max Deposits</div>
            </div>
            <div>
              <div className="text-4xl font-bold text-privacy-400">Zig</div>
              <div className="text-gray-400">Built With</div>
            </div>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="max-w-6xl mx-auto px-4 py-8 text-center text-gray-500 border-t border-gray-800">
        <p>
          Built for{' '}
          <a 
            href="https://solana.com/privacyhack" 
            target="_blank" 
            rel="noopener noreferrer"
            className="text-privacy-400 hover:underline"
          >
            Privacy Hack
          </a>
          {' '}| Compatible with{' '}
          <a 
            href="https://github.com/Privacy-Cash/privacy-cash" 
            target="_blank" 
            rel="noopener noreferrer"
            className="text-privacy-400 hover:underline"
          >
            Privacy Cash
          </a>
        </p>
      </footer>
    </main>
  );
}
