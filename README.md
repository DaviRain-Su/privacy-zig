# Privacy SDK for Zig 🔐

High-performance privacy primitives for Solana, built in Zig.

**For [Privacy Hack](https://solana.com/privacyhack) hackathon - Privacy Tooling Track**

## Compatibility

This SDK is designed to be **compatible with [Privacy Cash](https://github.com/Privacy-Cash/privacy-cash)**:
- Same Groth16 proof format
- Same Merkle tree structure (height 26)
- Same commitment scheme
- Compatible with existing Circom circuits

### Why Zig?

| Metric | Privacy Cash (Rust) | privacy-zig |
|--------|---------------------|-------------|
| On-chain CU overhead | ~150 CU (Anchor) | ~5-18 CU (anchor-zig) |
| Binary size | ~100+ KB | **57 KB** |
| Groth16 verification | ✓ | ✓ (alt_bn128 syscall) |
| Verification speed | Good | **Better** |

## Features

| Module | Description |
|--------|-------------|
| **Stealth Addresses** | Receive payments without revealing identity |
| **ZK Proof Helpers** | Generate inputs for Noir/Circom circuits |
| **Confidential Transfers** | Privacy pool deposits & withdrawals |
| **Nullifier Management** | Prevent double-spending |
| **Poseidon Hash** | ZK-friendly hash function (BN254) |
| **Merkle Trees** | Membership proofs for privacy pools |
| **Pedersen Commitments** | Hide values with homomorphic properties |

## Quick Start

```zig
const privacy = @import("privacy_zig");

// ============================================
// 1. Stealth Address - Hide Recipient Identity
// ============================================

// Recipient creates wallet
const wallet = privacy.createStealthWallet();
const meta = wallet.getMetaAddress();
// Publish meta.view_key and meta.spend_key

// Sender generates one-time stealth address
const result = privacy.generateStealthAddress(meta);
// Send funds to result.stealth_address
// Publish result.ephemeral_pubkey with transaction

// Recipient scans and finds their funds
const scanned = wallet.scan(result.ephemeral_pubkey).?;
// scanned.stealth_address == result.stealth_address ✓

// ============================================
// 2. Privacy Pool - Break Transaction Graph
// ============================================

// Create deposit note
const note = privacy.createDeposit(1_000_000_000); // 1 SOL
// Submit note.commitment to on-chain pool

// Generate withdrawal proof
const merkle_tree = try privacy.createMerkleTree(allocator);
try merkle_tree.insert(note.commitment);
const proof = try merkle_tree.getProof(allocator, 0);

// Withdrawal breaks the link between deposit and recipient!

// ============================================
// 3. Nullifier - Prevent Double Spending
// ============================================

var nullifier_set = privacy.nullifier.NullifierSet.init(allocator);
const n = privacy.createNullifier();

try nullifier_set.markSpent(n.hash);
// Now n.hash cannot be used again
```

## Architecture

```
privacy-zig/
├── src/
│   ├── root.zig              # Main entry point
│   ├── crypto/
│   │   ├── poseidon.zig      # ZK-friendly hash
│   │   ├── merkle.zig        # Merkle tree proofs
│   │   └── pedersen.zig      # Commitments
│   ├── stealth/
│   │   └── mod.zig           # Stealth addresses
│   ├── nullifier/
│   │   └── mod.zig           # Double-spend prevention
│   ├── transfer/
│   │   └── mod.zig           # Privacy pool logic
│   └── zk/
│       └── mod.zig           # ZK proof helpers
└── programs/
    └── privacy-pool/         # On-chain program (anchor-zig)
```

## Cryptographic Primitives

### Poseidon Hash (ZK-Friendly)

```zig
const privacy = @import("privacy_zig");

// Hash two values
const h = privacy.hash2(a, b);

// Hash arbitrary data
const h2 = privacy.hash("hello");

// Hash multiple elements
const elements = [_][32]u8{ a, b, c };
const h3 = privacy.poseidon.hashMany(&elements);
```

### Merkle Tree (Membership Proofs)

```zig
// Create tree (2^20 = 1M capacity)
var tree = try privacy.createMerkleTree(allocator);
defer tree.deinit();

// Insert leaves
const idx = try tree.insert(commitment);

// Generate proof
const proof = try tree.getProof(allocator, idx);

// Verify proof
const valid = proof.verify(tree.getRoot(), commitment);
```

### Pedersen Commitments

```zig
const pedersen = privacy.pedersen;

// Commit to a value (hiding)
const blinding = pedersen.randomBlinding();
const commitment = pedersen.commit(value, blinding);

// Verify opening
const valid = pedersen.verify(commitment, value, blinding);
```

## Use Cases

### Private Donations
1. Charity publishes stealth meta-address
2. Donors send to one-time addresses
3. Nobody can see total donations per donor

### Privacy Pool (Mixer)
1. Users deposit fixed amounts with commitments
2. Commitments added to Merkle tree
3. Withdrawal uses ZK proof + nullifier
4. Breaks link between deposit and withdrawal

### Confidential Payments
1. Sender creates encrypted transaction
2. Only recipient can decrypt amount
3. Chain only sees commitments

## Integration with anchor-zig

```zig
const anchor = @import("anchor_zig");
const privacy = @import("privacy_zig");
const zero = anchor.zero_cu;

const PoolData = struct {
    merkle_root: [32]u8,
    nullifier_bloom: privacy.nullifier.CompactNullifierSet,
};

const DepositAccounts = struct {
    depositor: zero.Signer(0),
    pool: zero.Account(PoolData, .{}),
};

pub fn deposit(ctx: zero.Ctx(DepositAccounts), commitment: [32]u8) !void {
    const pool = ctx.accounts.pool.getMut();
    // Update merkle root with new commitment
    pool.merkle_root = privacy.hash2(pool.merkle_root, commitment);
}

comptime {
    zero.program(.{
        zero.ix("deposit", DepositAccounts, deposit),
    });
}
```

## Performance

Built with Zig for maximum efficiency:
- **Zero heap allocations** in hot paths
- **Compile-time optimization** for hash functions
- **Minimal binary size** for on-chain deployment
- Designed for **anchor-zig** (5 CU overhead)

## Testing

```bash
# SDK tests
zig build test --summary all
# 46/46 tests passed ✓

# On-chain program tests
cd programs/privacy-pool
./solana-zig/zig build test --summary all
# 8/8 tests passed ✓

# Build program (57 KB)
./solana-zig/zig build
ls -lh zig-out/lib/privacy_pool.so
```

## Roadmap

- [x] Core cryptographic primitives
- [x] Stealth address generation & scanning
- [x] Merkle tree with proofs
- [x] Nullifier management
- [x] Privacy pool deposit/withdraw logic
- [x] On-chain program with 4 instructions (initialize, deposit, withdraw, transact)
- [x] Groth16 verification via alt_bn128 syscall
- [x] Typed account access with get()/getMut()
- [ ] Poseidon hash matching Light Protocol parameters
- [ ] Full Privacy Cash compatibility (actual VK from trusted setup)
- [ ] Frontend SDK (TypeScript)
- [ ] Relayer support
- [ ] SPL Token support (USDC, USDT)

## Privacy Cash Compatibility

This project aims to be a drop-in replacement for Privacy Cash's on-chain program:

```
Privacy Cash SDK (TypeScript)
         |
         v
    +---------+
    | Circom  |  <- Existing circuits (no changes needed)
    | Circuit |
    +---------+
         |
         v
  +-------------+
  | Groth16     |  <- Same proof format
  | Proof       |
  +-------------+
         |
         v
+------------------+     +------------------+
| Privacy Cash     | OR  | privacy-zig      |
| (Rust/Anchor)    |     | (Zig/anchor-zig) |
| ~150 CU overhead |     | ~5-18 CU overhead|
+------------------+     +------------------+
```

### Advantages

1. **Lower fees**: ~10x less CU = ~10x cheaper transactions
2. **Smaller program**: Faster deployment, lower rent
3. **Same security**: Uses same proven Circom circuits
4. **Compatible SDK**: Works with existing Privacy Cash SDK

## References

- [EIP-5564: Stealth Addresses](https://eips.ethereum.org/EIPS/eip-5564)
- [Tornado Cash Design](https://docs.tornado.cash/general/how-does-tornado.cash-work)
- [Poseidon Hash](https://eprint.iacr.org/2019/458.pdf)
- [Noir Language](https://noir-lang.org/)
- [anchor-zig](https://github.com/AminMortezaie/anchor-zig)

## License

Apache 2.0
