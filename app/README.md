# Privacy-Zig DApp

Anonymous Transfer on Solana - Break the transaction graph.

## Features

- 🔐 **Deposit SOL** - Generate a secret note and deposit into the privacy pool
- 💸 **Withdraw** - Use your note to withdraw to any address (no link to depositor!)
- 📝 **Manage Notes** - View and manage your deposit notes locally

## Quick Start

```bash
# Install dependencies
npm install

# Start development server
npm run dev
```

Open [http://localhost:3000](http://localhost:3000)

## How It Works

```
┌─────────────┐    deposit()    ┌──────────────┐   withdraw()    ┌─────────────┐
│   Alice     │ ────────────>   │   Privacy    │ ────────────>   │    Bob      │
│ (Sender)    │   commitment    │     Pool     │   ZK Proof      │ (New Addr)  │
└─────────────┘                 └──────────────┘                 └─────────────┘
```

1. **Deposit**: Alice deposits SOL and receives a secret note
2. **Pool Activity**: Other users deposit/withdraw (increases anonymity set)
3. **Withdraw**: Use the note + ZK proof to withdraw to a new address
4. **Privacy**: No on-chain link between Alice and the new address!

## Architecture

```
app/
├── src/
│   ├── app/
│   │   ├── page.tsx          # Landing page
│   │   ├── deposit/page.tsx  # Deposit flow
│   │   ├── withdraw/page.tsx # Withdrawal flow
│   │   └── notes/page.tsx    # Note management
│   ├── components/
│   │   ├── Header.tsx        # Navigation
│   │   └── WalletProvider.tsx
│   └── lib/
│       └── privacy.ts        # Core privacy functions
└── package.json
```

## Tech Stack

- **Next.js 14** - React framework
- **TailwindCSS** - Styling
- **@solana/wallet-adapter** - Wallet connection
- **circomlibjs** - Poseidon hash
- **snarkjs** - ZK proof generation

## Network

Currently configured for **Solana Devnet**. 

To switch networks, update `WalletProvider.tsx`:
```typescript
const endpoint = useMemo(() => clusterApiUrl('mainnet-beta'), []);
```

## Development

```bash
# Run dev server
npm run dev

# Build for production
npm run build

# Start production server
npm start
```

## Security Notes

⚠️ **Important**:
- Secret notes are stored in browser localStorage
- If you clear browser data, notes are lost forever
- Always back up your notes externally
- Never share your secret notes with anyone

## License

Apache 2.0
