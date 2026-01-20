# Privacy Pool DApp

A Next.js frontend for anonymous SOL transfers on Solana using zero-knowledge proofs.

## Features

| Page | Description |
|------|-------------|
| `/transfer` | **One-click anonymous transfer** - Send SOL privately without managing notes |
| `/deposit` | Deposit SOL to privacy pool, note saved to localStorage |
| `/withdraw` | Withdraw using saved notes to any address |
| `/notes` | View, export, import, and manage your private notes |

## How It Works

1. **Deposit**: User deposits SOL → ZK proof generated → Commitment added to Merkle tree → Note saved locally
2. **Withdraw**: User selects note → ZK proof generated with Merkle path → Funds sent to recipient
3. **Anonymous Transfer**: Combines deposit + withdraw in single flow (no notes needed)

## Privacy Guarantees

- ✅ No on-chain link between deposits and withdrawals
- ✅ ZK proofs verify transaction validity without revealing details
- ✅ Client-side proof generation (your secrets never leave your browser)
- ✅ No indexer/relayer required (Merkle tree reconstructed from on-chain data)

## Quick Start

```bash
# Install dependencies
npm install

# Run development server
npm run dev

# Open http://localhost:3000
```

## Configuration

The app connects to **Solana Testnet** by default.

Program addresses (in `src/lib/privacy.ts`):
```typescript
PROGRAM_ID: 'Dz82AAVPumnUys5SQ8HMat5iD6xiBVMGC2xJiJdZkpbT'
treeAccount: '2h8oJdtfe9AE8r3Dmp49iBruUMfQQMmo6r63q79vxUN1'
globalConfig: '9qQELDcp6Z48tLpsDs6RtSQbYx5GpquxB4staTKQz15i'
```

## Notes Storage

Private notes are stored in **browser localStorage**:

⚠️ **Important**: Notes will be lost if you:
- Clear browser data/cookies
- Use incognito/private mode  
- Switch browsers or devices

👉 Use the **Export** feature in `/notes` to backup your notes!

## Tech Stack

- **Next.js 14** - React framework
- **Tailwind CSS** - Styling
- **@solana/web3.js** - Solana interaction
- **@solana/wallet-adapter** - Wallet connection
- **snarkjs** - ZK proof generation
- **circomlibjs** - Poseidon hash

## Circuit Files

Place these in `public/circuits/`:
- `transaction2.wasm` - Circuit WASM
- `transaction2.zkey` - Proving key

These are from Privacy Cash's trusted setup.

## License

Apache 2.0
