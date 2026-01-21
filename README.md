# Privacy Pool on Solana 🔐

Anonymous SOL transfers using zero-knowledge proofs, built with Zig.

**For [Privacy Hack](https://solana.com/privacyhack) hackathon - Privacy Tooling Track**

## Features

- **Anonymous Transfers**: Send SOL with no on-chain link between sender and recipient (via relayer)
- **ZK Proofs**: Groth16 proofs verified on-chain via alt_bn128 syscall
- **Privacy Cash Compatible**: Uses same circuits and proof format
- **Relayer Support**: Withdrawal is submitted by a relayer to hide the sender address
- **Minimal Overhead**: Built with Zig for maximum performance (~160K CU per transaction)

## Architecture

```
privacy-zig/
├── programs/privacy-pool/  # On-chain Zig program (57 KB)
├── app/                    # Next.js DApp
├── scripts/                # Deployment & testing scripts
├── circuits/               # Circom circuit files
└── artifacts/              # Verifying keys
```

## Quick Start

### Run the DApp

```bash
cd app
npm install
npm run dev
# Open http://localhost:3000
```

### Run the Relayer

```bash
cd relayer
cargo run
```

Set the relayer URL in the app if needed:

```bash
export NEXT_PUBLIC_RELAYER_URL=http://localhost:3001
```

### CLI Usage

```bash
cd cli
cargo run -- --help
```

Common commands:

```bash
# Pool stats
cargo run -- stats

# Deposit 0.1 SOL
cargo run -- deposit --amount 0.1

# Withdraw to a recipient
cargo run -- withdraw --recipient <RECIPIENT_ADDRESS>

# One-click anonymous transfer (deposit + relayed withdraw)
cargo run -- transfer --amount 0.1 --recipient <RECIPIENT_ADDRESS>

# List saved notes
cargo run -- notes
```

You can override on-chain addresses via environment variables:

```bash
export PRIVACY_POOL_PROGRAM_ID=...
export PRIVACY_POOL_TREE_ACCOUNT=...
export PRIVACY_POOL_GLOBAL_CONFIG=...
export PRIVACY_POOL_POOL_VAULT=...
export PRIVACY_POOL_FEE_RECIPIENT=...
```

### Build On-chain Program

```bash
cd programs/privacy-pool
zig build
# Output: zig-out/lib/privacy_pool.so (57 KB)
```

## Live Demo (Testnet)

**Program ID**: `9A6fck3xNW2C6vwwqM4i1f4GeYpieuB7XKpF1YFduT6h`

| Account | Address |
|---------|---------|
| Tree Account | `4EGnTF2XfKDTBAszzoqQLe4zbmiURkWtkYQGnj99GiJf` |
| Global Config | `7RUeHfhA6L7BUrmt9ZK7SJ9rmTMkD8qjjJgHRrUEGMq9` |
| Pool Vault | `7nAKNHQwTeaybrnX6y3c3fLDL3qzQ3A6FGwMwH1LPc8q` |
| Fee Recipient | `FM7WTd5Hr7ppp6vu3M4uAspF4DoRjrYPPFvAmqB7H95D` |

## DApp Pages

| Page | Description |
|------|-------------|
| `/transfer` | **One-click anonymous transfer** - deposit + withdraw in single flow |
| `/deposit` | Deposit SOL, note saved to localStorage |
| `/withdraw` | Withdraw using saved notes |
| `/notes` | Manage, export, import notes |

## How It Works

```
1. DEPOSIT
   User deposits SOL → ZK proof generated → Commitment added to Merkle tree
   
2. WITHDRAW (via Relayer)
   User generates ZK proof → sends proof to relayer → relayer submits tx
   The relayer pays the transaction fee, so the user's address is hidden.
   
3. PRIVACY
   No on-chain link between deposit and withdrawal!
```

### Anonymous Transfer Flow

Anonymous transfers are implemented as **deposit + relayed withdraw**:

1. **Deposit (public)**: User deposits SOL to the pool and creates a note.
2. **Withdraw (private)**: The app generates a ZK proof and sends it to the relayer.
3. **Relayer submit**: The relayer submits the withdrawal transaction so the
   on-chain sender is the relayer, not the user.

This preserves privacy while keeping the pool verifiable on-chain.

### Zero-Knowledge Circuit

Uses Privacy Cash's `transaction2.circom` which proves:
- User knows the secret (nullifier, blinding) for a commitment in the tree
- The nullifier hasn't been used before (prevents double-spend)
- The amount balances (inputs = outputs + public amount)

## Performance

| Metric | Privacy Cash (Rust) | privacy-zig |
|--------|---------------------|-------------|
| Program size | ~100+ KB | **57 KB** |
| Transaction CU | ~200K+ | **~160K** |
| Framework overhead | ~150 CU (Anchor) | ~5-18 CU (anchor-zig) |

## Roadmap

### ✅ Completed
- [x] On-chain program with Groth16 verification
- [x] Testnet deployment
- [x] Full DApp (transfer, deposit, withdraw, notes)
- [x] Browser ZK proof generation
- [x] Client-side Merkle tree reconstruction
- [x] Privacy Cash circuit compatibility

### 📋 Planned
- [ ] Relayer support
- [ ] SPL Token support (USDC, USDT)
- [ ] Mainnet deployment
- [ ] Mobile wallet support

## Tech Stack

**On-chain**:
- Zig + solana-zig SDK
- anchor-zig for account management
- alt_bn128 syscall for pairing checks

**Frontend**:
- Next.js 14 + TypeScript
- snarkjs for proof generation
- circomlibjs for Poseidon hash
- @solana/wallet-adapter

## References

- [Privacy Cash](https://github.com/Privacy-Cash/privacy-cash)
- [Tornado Cash Design](https://docs.tornado.cash/)
- [anchor-zig](https://github.com/AminMortezaie/anchor-zig)
- [solana-zig SDK](https://github.com/solana-zig/solana-zig)
- [Solana zkLogin + Passkey 概要](docs/solana-zklogin-passkey.md)

## License

Apache 2.0
