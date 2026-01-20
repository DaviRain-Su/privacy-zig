# @privacy-zig/sdk

TypeScript SDK for Privacy-Zig on Solana.

## Features

- **Anchor IDL Integration** - Auto-generated types from IDL
- **Commitment Generation** - Create deposit commitments using Poseidon hash
- **Merkle Tree** - Track commitments and generate proofs
- **ZK Proof Integration** - Compatible with Privacy Cash's Circom circuits

## Installation

```bash
npm install @privacy-zig/sdk
```

## Quick Start

```typescript
import { 
  PrivacyPoolClient, 
  MerkleTree, 
  createUtxo,
  PROGRAM_ID,
} from '@privacy-zig/sdk';

// Initialize client
const client = new PrivacyPoolClient(provider);

// Create deposit commitment
const { utxo, commitment, blinding } = await createUtxo(
  1_000_000_000n, // 1 SOL
  recipientPubkey,
  SystemProgram.programId
);

// Track in Merkle tree
const tree = new MerkleTree();
await tree.init();
const leafIndex = tree.insert(commitment);

// Get Merkle proof
const proof = tree.getProof(leafIndex);
```

## Anonymous Transfer Flow

```
┌─────────────┐    deposit()    ┌──────────────┐   withdraw()    ┌─────────────┐
│   Alice     │ ────────────>   │   Privacy    │ ────────────>   │    Bob      │
│ (Sender)    │   commitment    │     Pool     │   ZK Proof      │ (New Addr)  │
└─────────────┘                 └──────────────┘                 └─────────────┘
```

1. **Alice deposits** with commitment = hash(secret, nullifier, amount)
2. **Commitment added** to on-chain Merkle tree
3. **Bob generates ZK proof** using snarkjs + Privacy Cash circuits
4. **Bob withdraws** to new address - **no link to Alice!**

## API Reference

### `PrivacyPoolClient`

```typescript
const client = new PrivacyPoolClient(provider);

// Initialize pool
await client.initialize(treeAccount, globalConfig, maxDeposit, feeRecipient);

// Execute transact (deposit/withdraw/transfer)
await client.transact(accounts, args);

// Fetch accounts
const tree = await client.fetchTreeAccount(address);
const config = await client.fetchGlobalConfig(address);

// Parse events
const events = client.parseCommitmentEvents(logs);
```

### `MerkleTree`

```typescript
const tree = new MerkleTree(26); // Height 26 = 67M leaves
await tree.init();

// Insert commitment
const index = tree.insert(commitment);

// Get root
const root = tree.getRoot();

// Get proof
const { pathElements, pathIndices } = tree.getProof(index);
```

### `createUtxo`

```typescript
const { utxo, commitment, blinding } = await createUtxo(
  amount,      // bigint
  pubkey,      // bigint
  mintAddress  // PublicKey (SystemProgram.programId for SOL)
);
```

## ZK Proof Generation

This SDK works with Privacy Cash's Circom circuits:

```typescript
import * as snarkjs from 'snarkjs';

// Generate proof
const { proof, publicSignals } = await snarkjs.groth16.fullProve(
  circuitInputs,
  'circuits/transaction.wasm',
  'circuits/transaction.zkey'
);

// Format for on-chain
const formattedProof = {
  a: new Uint8Array([...proof.pi_a[0], ...proof.pi_a[1]]),
  b: new Uint8Array([...proof.pi_b[0][0], ...proof.pi_b[0][1], ...proof.pi_b[1][0], ...proof.pi_b[1][1]]),
  c: new Uint8Array([...proof.pi_c[0], ...proof.pi_c[1]]),
};
```

## Compatibility

- **Privacy Cash** - Same commitment scheme, same Circom circuits
- **Anchor** - Standard IDL format
- **Solana Web3.js** - Native integration

## License

Apache 2.0
