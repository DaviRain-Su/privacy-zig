# Privacy Hack Strategy

> [Privacy Hack](https://solana.com/privacyhack) hackathon planning document

## Current Status

**privacy-zig** is a working anonymous transfer system on Solana Testnet:
- ✅ On-chain Zig program (86 KB, ~160K CU deposit)
- ✅ Next.js DApp with wallet integration
- ✅ ZK proof generation in browser
- ✅ Privacy Cash circuit compatibility
- ✅ Benchmark comparison completed

## 📊 Benchmark Results (Actual Data)

| Metric | privacy-zig | Privacy Cash | Improvement |
|--------|-------------|--------------|-------------|
| **Program Size** | **86 KB** | 484 KB | **5.7x smaller** ✅ |
| **Deposit CU** | ~163K | ~163K* | Same |
| **Withdraw CU** | ~929K | ~929K* | Same |
| **Framework Overhead** | **5-18 CU** | ~150 CU | **8-30x less** ✅ |
| **Deployment Rent** | **~0.6 SOL** | ~3.4 SOL | **Saves 2.8 SOL** ✅ |

*\* CU is same because both use identical circuits and syscalls*

See [BENCHMARK.md](./BENCHMARK.md) for detailed analysis.

---

## Hackathon Tracks

| Track | Prize | Fit | Notes |
|-------|-------|-----|-------|
| **Privacy Tooling** | $15,000 | ⭐⭐⭐⭐⭐ | Best fit - we're building dev tools |
| Private Payments | $15,000 | ⭐⭐⭐ | Already implemented but not innovative enough |
| Open Track | $18,000 | ⭐⭐⭐ | Supported by Light Protocol |

---

## Sponsor Bounties

### Privacy Cash - $6,000 ⭐⭐⭐⭐⭐ BEST FIT

We use their circuits! Position as "High-performance Zig implementation".

| Prize | Amount |
|-------|--------|
| Grand Prize | $3,000 |
| Best Integration to Existing App | $1,500 |
| Honorable Mentions | $500 x 3 |

**Our advantage**:
- Same circuits (transaction2.circom)
- 5.7x smaller program size
- 8-30x less framework overhead
- Saves 2.8 SOL deployment rent
- Drop-in replacement
- Complete DApp included

**Resources**:
- GitHub: https://github.com/Privacy-Cash/privacy-cash

---

### Aztec (Noir) - $10,000 ⭐⭐

Build ZK applications using Noir on Solana.

| Prize | Amount |
|-------|--------|
| Best Overall | $5,000 |
| Best Non-Financial Use | $2,500 |
| Most Creative | $2,500 |

**What we'd need**:
- Integrate Sunspot verifier (Noir/Groth16 on Solana)
- Rewrite circuits in Noir instead of Circom
- Significant effort but higher prize

**Resources**:
- Noir Docs: https://noir-lang.org/docs/
- Sunspot Verifier: https://github.com/reilabs/sunspot
- Noir on Solana Examples: https://github.com/solana-foundation/noir-examples

---

### Helius - $5,000 ⭐⭐⭐

Best privacy project leveraging Helius RPCs and developer tooling.

**What we could add**:
- Use Helius RPC for faster transaction fetching
- Build indexer service using Helius webhooks
- Better Merkle tree reconstruction with Helius APIs

**Resources**:
- Website: https://helius.dev
- Docs: https://docs.helius.dev/
- GitHub: https://github.com/helius-labs

---

### Inco - $6,000 ⭐⭐

Best confidential apps using Inco Lightning.

| Category | Amount |
|----------|--------|
| DeFi | $2,000 |
| Consumer/Gaming/Prediction Markets | $2,000 |
| Payments | $2,000 |

**Resources**:
- Docs: https://docs.inco.org/svm/home
- Website: https://inco.org

---

### Arcium - $10,000 ⭐⭐

End-to-end private DeFi using Arcium and C-SPL token standard.

**Would need**:
- Integrate Arcium MPC network
- Build confidential swaps/lending
- Different tech stack (MPC vs ZK)

**Resources**:
- Website: https://arcium.com
- Docs: https://docs.arcium.com/
- Examples: https://github.com/arcium-hq/examples

---

### Radr Labs - $15,000 ⭐⭐

Privacy-First DeFi: ShadowWire, ShadowSwap, ShadowTrade.

**Resources**:
- Website: https://radr.fun
- API Docs: https://registry.scalar.com/@radr/apis/shadowpay-api
- GitHub: https://github.com/radrdotfun

---

### Range - $1,500 ⭐⭐

Compliant-privacy solutions using Range tools for screening and selective disclosure.

**Resources**:
- Website: https://www.range.org

---

### Encrypt.trade - $1,000 ⭐

Educate users about privacy.

| Prize | Amount |
|-------|--------|
| Wallet Surveillance Education | $500 |
| Jargon-Free Privacy Explanation | $500 |

---

## Recommended Strategy

### Option A: Privacy Cash Bounty ($6,000) - EASIEST ✅ RECOMMENDED

**Positioning**: "High-performance Zig implementation of Privacy Cash"

**What to highlight**:
```
┌─────────────────────┬──────────────┬──────────────┬─────────────┐
│ Metric              │ privacy-zig  │ Privacy Cash │ Improvement │
├─────────────────────┼──────────────┼──────────────┼─────────────┤
│ Program Size        │      86 KB   │     484 KB   │ 5.7x smaller│
│ Framework Overhead  │    5-18 CU   │    ~150 CU   │ 8-30x less  │
│ Deployment Rent     │   ~0.6 SOL   │   ~3.4 SOL   │ Saves 2.8   │
│ Circuit Compatible  │      ✅      │      ✅      │ Same        │
│ Has DApp            │      ✅      │      ❌      │ We win!     │
└─────────────────────┴──────────────┴──────────────┴─────────────┘
```

**TODO**:
- [x] Add comparison benchmarks ✅ (BENCHMARK.md)
- [ ] Document API compatibility
- [ ] Create migration guide from Privacy Cash
- [ ] Record demo video (max 3 minutes)

**Demo Video Outline** (3 min):
1. **Intro** (30s): "privacy-zig - Faster, smaller Privacy Cash implementation"
2. **Benchmark** (30s): Show size/CU comparison
3. **DApp Demo** (90s): 
   - Connect wallet
   - One-click anonymous transfer
   - Show deposit/withdraw flow
   - Show notes management
4. **Code** (20s): Show clean Zig code vs Rust
5. **Outro** (10s): Links, call to action

---

### Option B: Privacy Tooling Track ($15,000) - MEDIUM EFFORT

**Positioning**: "Zig SDK for building privacy applications on Solana"

**What to add**:
- [ ] CLI tool for deposit/withdraw
- [ ] Reusable Groth16 verifier library
- [ ] Template project for developers
- [ ] NPM package for TypeScript integration
- [ ] Comprehensive documentation

**Deliverables**:
```
privacy-zig/
├── programs/           # On-chain Zig programs
├── cli/                # Command-line tool (NEW)
├── sdk/                # Reusable libraries (NEW)
│   ├── verifier/       # Groth16 verifier
│   └── typescript/     # TS/JS bindings
├── templates/          # Starter templates (NEW)
├── app/                # Demo DApp
└── docs/               # Full documentation (NEW)
```

---

### Option C: Aztec/Noir Integration ($10,000) - HARD

**Positioning**: "Noir-powered privacy on Solana with Zig performance"

**What to build**:
- [ ] Integrate Sunspot Noir verifier
- [ ] Port transaction circuit to Noir
- [ ] Maintain Zig program performance

**Risk**: Significant rewrite, new tech to learn

---

## Submission Checklist

- [x] Open source code (Apache 2.0)
- [x] Integrate Solana with privacy-preserving technologies
- [x] Deploy to Solana testnet
- [x] Benchmark comparison (BENCHMARK.md)
- [ ] Demo video (max 3 minutes)
- [ ] API compatibility documentation
- [ ] Migration guide

## Live Testnet Deployment

| Component | Address |
|-----------|---------|
| Program ID | `Dz82AAVPumnUys5SQ8HMat5iD6xiBVMGC2xJiJdZkpbT` |
| Tree Account | `2h8oJdtfe9AE8r3Dmp49iBruUMfQQMmo6r63q79vxUN1` |
| Global Config | `9qQELDcp6Z48tLpsDs6RtSQbYx5GpquxB4staTKQz15i` |
| Pool Vault | `Cd6ntF7dtCqWiEnitLyukEVKN7VaCVkF1ta9VryP2zYq` |

## DApp Features

| Page | Feature |
|------|---------|
| `/transfer` | One-click anonymous transfer |
| `/deposit` | Deposit with note saved to localStorage |
| `/withdraw` | Withdraw using saved notes |
| `/notes` | Manage, export, import notes |

---

## Resources to Study

### Tooling
- [Sunspot](https://github.com/reilabs/sunspot) - Noir/Groth16 verifier on Solana
- [Light Protocol](https://github.com/Lightprotocol/light-protocol) - ZK compression
- [groth16-solana](https://github.com/Lightprotocol/groth16-solana) - Groth16 verifier

### Education
- [Noir examples](https://github.com/solana-foundation/noir-examples)
- [Solana mixer example](https://github.com/catmcgee/solana-mixer-circom)
- [Confidential transfers guide](https://solana.com/docs/tokens/extensions/confidential-transfer)

### Research
- [ZK Architecture on Solana](https://arxiv.org/abs/2511.00415)

---

## Competition Analysis

| Project | Tech | Frontend | Status |
|---------|------|----------|--------|
| Privacy Cash | Rust/Anchor + Circom | ❌ None | SDK only |
| Arcium | MPC network | ✅ | Production |
| encrypt.trade | TEEs | ✅ | Production |
| Umbra | Shielded pools (Arcium) | ✅ | Production |
| Hush | Stealth addresses | ✅ | Active |
| **privacy-zig** | **Zig + Circom** | **✅ Full DApp** | **Testnet** |

## Our Unique Value Proposition

1. **Performance**: 5.7x smaller program, 8-30x less framework overhead
2. **Compatibility**: Drop-in replacement for Privacy Cash circuits
3. **Complete Solution**: Full DApp included (Privacy Cash has none!)
4. **Developer-friendly**: Clean Zig code, good documentation
5. **Cost Savings**: 2.8 SOL less deployment rent

---

## Next Steps

1. [ ] Decide on target bounty (recommend: Privacy Cash $6k)
2. [ ] Write API compatibility docs
3. [ ] Create migration guide
4. [ ] Record 3-minute demo video
5. [ ] Submit before deadline

## Timeline

| Task | Time Estimate |
|------|---------------|
| API docs | 2-3 hours |
| Migration guide | 2-3 hours |
| Demo video | 3-4 hours |
| Final testing | 1-2 hours |
| **Total** | **8-12 hours** |
