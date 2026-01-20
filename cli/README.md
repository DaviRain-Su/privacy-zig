# privacy-cli

Command-line interface for anonymous SOL transfers on Solana.

## Installation

### From Source

```bash
cd cli
cargo build --release
# Binary at: ./target/release/privacy
```

### Add to PATH

```bash
cp ./target/release/privacy ~/.local/bin/
# or
sudo cp ./target/release/privacy /usr/local/bin/
```

## Usage

```bash
# Show help
privacy --help

# Show pool statistics
privacy stats

# Show wallet and program info
privacy info

# Deposit SOL to privacy pool
privacy deposit --amount 0.1

# Withdraw to any address
privacy withdraw --recipient <ADDRESS>

# One-click anonymous transfer
privacy transfer --amount 0.1 --recipient <ADDRESS>

# Manage notes
privacy notes list
privacy notes export --file backup.json
privacy notes import --file backup.json
privacy notes delete --id <NOTE_ID>
```

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-r, --rpc-url` | Solana RPC URL | `https://api.testnet.solana.com` |
| `-k, --keypair` | Path to keypair file | `~/.config/solana/id.json` |

## Commands

### `stats`

Show privacy pool statistics:
- Pool vault balance
- Total deposits
- Network

### `deposit`

Deposit SOL to the privacy pool. A note is saved locally for later withdrawal.

```bash
privacy deposit --amount 0.1
```

### `withdraw`

Withdraw from the privacy pool using a saved note.

```bash
# Interactive note selection
privacy withdraw --recipient <ADDRESS>

# Specify note ID
privacy withdraw --recipient <ADDRESS> --note-id <NOTE_ID>
```

### `transfer`

One-click anonymous transfer. Deposits and immediately withdraws to recipient.

```bash
privacy transfer --amount 0.1 --recipient <ADDRESS>
```

### `notes`

Manage your private notes.

```bash
# List all notes
privacy notes list

# Export to backup file
privacy notes export --file backup.json

# Import from backup
privacy notes import --file backup.json

# Delete a note (careful!)
privacy notes delete --id note_12345
```

## Notes Storage

Notes are stored in `~/.privacy-zig/notes.json`.

⚠️ **Important**: Backup your notes! Losing them means losing access to deposited funds.

## Example Session

```bash
$ privacy stats
📊 Pool Statistics
────────────────────────────────────────
  Pool Vault:      0.5100 SOL
  Total Deposits:  13
  Network:         Testnet

$ privacy deposit --amount 0.1
📥 Deposit
────────────────────────────────────────
  Amount:  0.1000 SOL
  From:    FM7W...95D

? Proceed with deposit? Yes
✓ Generating ZK proof...
✓ Sending transaction...
✅ Deposit successful!

$ privacy transfer --amount 0.05 --recipient 9xyz...abc
⚡ Anonymous Transfer
────────────────────────────────────────
  Amount:     0.0500 SOL
  Recipient:  9xyz...abc

? Proceed with anonymous transfer? Yes
✓ [1/4] Generating deposit proof...
✓ [2/4] Sending deposit transaction...
✓ [3/4] Generating withdrawal proof...
✓ [4/4] Sending withdrawal transaction...
✅ Anonymous transfer complete!

🔐 Privacy achieved:
   • No on-chain link between you and recipient
   • Transaction passed through ZK privacy pool
```

## License

Apache 2.0
