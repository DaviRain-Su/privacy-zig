use anyhow::{anyhow, Result};
use clap::{Parser, Subcommand};
use console::style;
use dialoguer::{Confirm, Select};
use indicatif::{ProgressBar, ProgressStyle};
use solana_client::rpc_client::RpcClient;
use solana_sdk::{
    commitment_config::CommitmentConfig,
    compute_budget::ComputeBudgetInstruction,
    instruction::{AccountMeta, Instruction},
    pubkey::Pubkey,
    signature::{read_keypair_file, Keypair, Signer},
    system_program,
    transaction::Transaction,
};
use std::str::FromStr;
use std::time::Duration;

mod crypto;
mod notes;
mod pool;
mod prover;

use crypto::{MerkleTree, Utxo, MERKLE_TREE_HEIGHT};
use notes::{Note, NoteStore};
use pool::{PoolConfig, PROGRAM_ID};
use prover::PrivacyProver;

#[derive(Parser)]
#[command(name = "privacy")]
#[command(author = "privacy-zig")]
#[command(version = "0.1.0")]
#[command(about = "Anonymous SOL transfers on Solana", long_about = None)]
struct Cli {
    /// Solana RPC URL
    #[arg(short, long, default_value = "https://api.testnet.solana.com")]
    rpc_url: String,

    /// Path to keypair file
    #[arg(short, long, default_value_t = default_keypair_path())]
    keypair: String,

    /// Path to circuit artifacts directory
    #[arg(short, long, default_value_t = default_artifacts_path())]
    artifacts: String,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Show pool statistics
    Stats,

    /// Deposit SOL to privacy pool
    Deposit {
        /// Amount in SOL
        #[arg(short, long)]
        amount: f64,

        /// Skip confirmation prompt
        #[arg(short, long, default_value_t = false)]
        yes: bool,
    },

    /// Withdraw SOL from privacy pool
    Withdraw {
        /// Recipient address
        #[arg(short, long)]
        recipient: String,

        /// Note ID to use (optional, will prompt if not provided)
        #[arg(short, long)]
        note_id: Option<String>,

        /// Skip confirmation prompt
        #[arg(short, long, default_value_t = false)]
        yes: bool,
    },

    /// One-click anonymous transfer (deposit + withdraw)
    Transfer {
        /// Amount in SOL
        #[arg(short, long)]
        amount: f64,

        /// Recipient address
        #[arg(short, long)]
        recipient: String,

        /// Skip confirmation prompt
        #[arg(short, long, default_value_t = false)]
        yes: bool,
    },

    /// List all notes
    Notes {
        #[command(subcommand)]
        action: Option<NotesAction>,
    },

    /// Show program info
    Info,
}

#[derive(Subcommand)]
enum NotesAction {
    /// List all notes
    List,
    /// Export notes to file
    Export {
        #[arg(short, long, default_value = "notes_backup.json")]
        file: String,
    },
    /// Import notes from file
    Import {
        #[arg(short, long)]
        file: String,
    },
    /// Delete a note
    Delete {
        #[arg(short, long)]
        id: String,
    },
}

fn default_keypair_path() -> String {
    dirs::home_dir()
        .map(|p| p.join(".config/solana/id.json").to_string_lossy().to_string())
        .unwrap_or_else(|| "~/.config/solana/id.json".to_string())
}

fn default_artifacts_path() -> String {
    // Try to find artifacts relative to crate or in common locations
    let locations = [
        "../artifacts",
        "../../privacy-zig/artifacts",
        "./artifacts",
    ];
    
    for loc in locations {
        let path = std::path::Path::new(loc);
        if path.exists() && path.join("transaction2.wasm").exists() {
            return loc.to_string();
        }
    }
    
    "../artifacts".to_string()
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    print_banner();

    let client = RpcClient::new_with_commitment(
        cli.rpc_url.clone(),
        CommitmentConfig::confirmed(),
    );

    let keypair = read_keypair_file(&cli.keypair)
        .map_err(|e| anyhow!("Failed to read keypair from {}: {}", cli.keypair, e))?;

    match cli.command {
        Commands::Stats => cmd_stats(&client).await?,
        Commands::Deposit { amount, yes } => {
            cmd_deposit(&client, &keypair, amount, &cli.artifacts, yes).await?
        }
        Commands::Withdraw { recipient, note_id, yes } => {
            cmd_withdraw(&client, &keypair, &recipient, note_id, &cli.artifacts, yes).await?
        }
        Commands::Transfer { amount, recipient, yes } => {
            cmd_transfer(&client, &keypair, amount, &recipient, &cli.artifacts, yes).await?
        }
        Commands::Notes { action } => cmd_notes(action).await?,
        Commands::Info => cmd_info(&client, &keypair).await?,
    }

    Ok(())
}

fn print_banner() {
    println!();
    println!("{}", style("  🔒 privacy-zig CLI").bold().cyan());
    println!("{}", style("  Anonymous SOL transfers on Solana").dim());
    println!();
}

async fn cmd_stats(client: &RpcClient) -> Result<()> {
    println!("{}", style("📊 Pool Statistics").bold());
    println!("{}", style("─".repeat(40)).dim());

    let config = PoolConfig::default();

    let vault_balance = client.get_balance(&config.pool_vault)?;
    let vault_sol = vault_balance as f64 / 1_000_000_000.0;

    let tree_data = client.get_account_data(&config.tree_account)?;
    let leaf_index = if tree_data.len() >= 48 {
        u64::from_le_bytes(tree_data[40..48].try_into().unwrap())
    } else {
        0
    };

    println!("  Pool Vault:      {} SOL", style(format!("{:.4}", vault_sol)).green());
    println!("  Total Deposits:  {}", style(leaf_index / 2).yellow());
    println!("  Network:         {}", style("Testnet").cyan());
    println!();

    Ok(())
}

async fn cmd_deposit(
    client: &RpcClient,
    keypair: &Keypair,
    amount: f64,
    artifacts_path: &str,
    skip_confirm: bool,
) -> Result<()> {
    let lamports = (amount * 1_000_000_000.0) as u64;

    println!("{}", style("📥 Deposit").bold());
    println!("{}", style("─".repeat(40)).dim());
    println!("  Amount:  {} SOL", style(format!("{:.4}", amount)).green());
    println!("  From:    {}", style(keypair.pubkey().to_string()).dim());
    println!();

    // Check balance
    let balance = client.get_balance(&keypair.pubkey())?;
    if balance < lamports + 10_000_000 {
        return Err(anyhow!(
            "Insufficient balance. Have {} SOL, need {} SOL + fees",
            balance as f64 / 1e9,
            amount
        ));
    }

    if !skip_confirm {
        if !Confirm::new()
            .with_prompt("Proceed with deposit?")
            .default(true)
            .interact()?
        {
            println!("{}", style("Cancelled").red());
            return Ok(());
        }
    }

    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .template("{spinner:.green} {msg}")
            .unwrap(),
    );
    pb.enable_steady_tick(Duration::from_millis(100));

    // Load prover
    pb.set_message("Loading circuit...");
    let wasm_path = format!("{}/transaction2.wasm", artifacts_path);
    let zkey_path = format!("{}/transaction2.zkey", artifacts_path);
    
    let prover = PrivacyProver::new(&wasm_path, &zkey_path)?;

    // Generate UTXO
    pb.set_message("Generating UTXO...");
    let utxo = Utxo::new(lamports)?;

    // Generate proof
    pb.set_message("Generating ZK proof (this takes ~30s)...");
    let payer_bytes: [u8; 32] = keypair.pubkey().to_bytes();
    let proof_data = prover.prove_deposit(lamports, &utxo, &payer_bytes)?;

    // Get current leaf index
    let config = PoolConfig::default();
    let tree_info = client.get_account_data(&config.tree_account)?;
    let current_leaf_index = if tree_info.len() >= 48 {
        u64::from_le_bytes(tree_info[40..48].try_into().unwrap()) as usize
    } else {
        0
    };

    // Build transaction
    pb.set_message("Building transaction...");
    let instruction_data = proof_data.to_instruction_data();

    // Derive nullifier PDAs
    let (nullifier1_pda, _) = Pubkey::find_program_address(
        &[b"nullifier", &proof_data.nullifier1],
        &config.program_id,
    );
    let (nullifier2_pda, _) = Pubkey::find_program_address(
        &[b"nullifier", &proof_data.nullifier2],
        &config.program_id,
    );

    let transact_ix = Instruction {
        program_id: config.program_id,
        accounts: vec![
            AccountMeta::new(config.tree_account, false),
            AccountMeta::new(nullifier1_pda, false),
            AccountMeta::new(nullifier2_pda, false),
            AccountMeta::new_readonly(config.global_config, false),
            AccountMeta::new(config.pool_vault, false),
            AccountMeta::new(keypair.pubkey(), true),
            AccountMeta::new(keypair.pubkey(), false), // fee recipient
            AccountMeta::new_readonly(system_program::id(), false),
        ],
        data: instruction_data,
    };

    let compute_ix = ComputeBudgetInstruction::set_compute_unit_limit(1_400_000);

    let recent_blockhash = client.get_latest_blockhash()?;
    let tx = Transaction::new_signed_with_payer(
        &[compute_ix, transact_ix],
        Some(&keypair.pubkey()),
        &[keypair],
        recent_blockhash,
    );

    // Send transaction
    pb.set_message("Sending transaction...");
    let signature = client.send_and_confirm_transaction(&tx)?;

    pb.finish_with_message("Done!");

    println!();
    println!("{}", style("✅ Deposit successful!").green().bold());
    println!("Signature: {}", signature);
    println!(
        "Explorer: https://explorer.solana.com/tx/{}?cluster=testnet",
        signature
    );

    // Save note
    let mut store = NoteStore::load()?;
    let note = Note {
        id: notes::generate_note_id(),
        amount: lamports,
        privkey: utxo.privkey,
        pubkey: utxo.pubkey,
        blinding: utxo.blinding,
        commitment: utxo.commitment,
        leaf_index: current_leaf_index as i64,
        status: "deposited".to_string(),
        created_at: chrono::Utc::now().timestamp() as u64,
        deposit_tx_sig: Some(signature.to_string()),
        withdraw_tx_sig: None,
    };
    store.add(note)?;

    println!();
    println!("{}", style("⚠️  Note saved to ~/.privacy-zig/notes.json").yellow());
    println!("{}", style("   Make sure to backup your notes!").yellow());
    println!();

    Ok(())
}

async fn cmd_withdraw(
    client: &RpcClient,
    keypair: &Keypair,
    recipient: &str,
    note_id: Option<String>,
    artifacts_path: &str,
    skip_confirm: bool,
) -> Result<()> {
    let recipient_pubkey = Pubkey::from_str(recipient)
        .map_err(|_| anyhow!("Invalid recipient address"))?;

    let store = NoteStore::load()?;
    let available_notes: Vec<_> = store.notes.iter().filter(|n| n.status == "deposited").collect();

    if available_notes.is_empty() {
        println!("{}", style("❌ No withdrawable notes found.").red());
        println!("   Use 'privacy deposit' first.");
        return Ok(());
    }

    let note = if let Some(id) = note_id {
        available_notes
            .iter()
            .find(|n| n.id == id)
            .ok_or_else(|| anyhow!("Note {} not found", id))?
    } else if skip_confirm {
        // When skipping confirm, use latest note
        available_notes.last().ok_or_else(|| anyhow!("No note found"))?
    } else {
        let items: Vec<String> = available_notes
            .iter()
            .map(|n| format!("{} - {} SOL", n.id, n.amount as f64 / 1e9))
            .collect();

        let selection = Select::new()
            .with_prompt("Select note to withdraw")
            .items(&items)
            .interact()?;

        available_notes[selection]
    };

    let amount_sol = note.amount as f64 / 1_000_000_000.0;

    println!("{}", style("📤 Withdraw").bold());
    println!("{}", style("─".repeat(40)).dim());
    println!("  Amount:     {} SOL", style(format!("{:.4}", amount_sol)).green());
    println!("  Recipient:  {}", style(recipient).cyan());
    println!("  Note ID:    {}", style(&note.id).dim());
    println!();

    if !skip_confirm {
        if !Confirm::new()
            .with_prompt("Proceed with withdrawal?")
            .default(true)
            .interact()?
        {
            println!("{}", style("Cancelled").red());
            return Ok(());
        }
    }

    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .template("{spinner:.green} {msg}")
            .unwrap(),
    );
    pb.enable_steady_tick(Duration::from_millis(100));

    // Load prover
    pb.set_message("Loading circuit...");
    let wasm_path = format!("{}/transaction2.wasm", artifacts_path);
    let zkey_path = format!("{}/transaction2.zkey", artifacts_path);
    let prover = PrivacyProver::new(&wasm_path, &zkey_path)?;

    // Reconstruct UTXO from note
    let utxo = Utxo::from_values(
        note.amount,
        &note.privkey,
        &note.pubkey,
        &note.blinding,
    )?;

    // Fetch commitments and rebuild tree
    pb.set_message("Fetching Merkle tree from chain...");
    let config = PoolConfig::default();
    let commitments = fetch_commitments_from_chain(client, &config)?;

    let mut tree = MerkleTree::new(MERKLE_TREE_HEIGHT);
    for c in &commitments {
        tree.insert(*c);
    }

    // Find our commitment in tree
    let commitment_fr = crypto::str_to_fr(&note.commitment)?;
    let leaf_index = tree
        .leaves
        .iter()
        .position(|&l| l == commitment_fr)
        .ok_or_else(|| anyhow!("Commitment not found in tree"))?;

    // Generate proof
    pb.set_message("Generating ZK proof (this takes ~30s)...");
    let recipient_bytes: [u8; 32] = recipient_pubkey.to_bytes();
    let proof_data = prover.prove_withdraw(&utxo, leaf_index, &tree, &recipient_bytes)?;

    // Build transaction
    pb.set_message("Building transaction...");
    let instruction_data = proof_data.to_instruction_data();

    let (nullifier1_pda, _) = Pubkey::find_program_address(
        &[b"nullifier", &proof_data.nullifier1],
        &config.program_id,
    );
    let (nullifier2_pda, _) = Pubkey::find_program_address(
        &[b"nullifier", &proof_data.nullifier2],
        &config.program_id,
    );

    let transact_ix = Instruction {
        program_id: config.program_id,
        accounts: vec![
            AccountMeta::new(config.tree_account, false),
            AccountMeta::new(nullifier1_pda, false),
            AccountMeta::new(nullifier2_pda, false),
            AccountMeta::new_readonly(config.global_config, false),
            AccountMeta::new(config.pool_vault, false),
            AccountMeta::new(keypair.pubkey(), true),
            AccountMeta::new(recipient_pubkey, false),
            AccountMeta::new_readonly(system_program::id(), false),
        ],
        data: instruction_data,
    };

    let compute_ix = ComputeBudgetInstruction::set_compute_unit_limit(1_400_000);

    let recent_blockhash = client.get_latest_blockhash()?;
    let tx = Transaction::new_signed_with_payer(
        &[compute_ix, transact_ix],
        Some(&keypair.pubkey()),
        &[keypair],
        recent_blockhash,
    );

    pb.set_message("Sending transaction...");
    let signature = client.send_and_confirm_transaction(&tx)?;

    pb.finish_with_message("Done!");

    // Update note status
    let mut store = NoteStore::load()?;
    store.update_status(&note.id, "withdrawn", Some(&signature.to_string()))?;

    println!();
    println!("{}", style("✅ Withdrawal successful!").green().bold());
    println!("Amount: {} SOL", amount_sol);
    println!("Recipient: {}", recipient);
    println!("Signature: {}", signature);
    println!();
    println!("{}", style("🔐 No on-chain link between your deposit and this withdrawal!").cyan());
    println!();

    Ok(())
}

async fn cmd_transfer(
    client: &RpcClient,
    keypair: &Keypair,
    amount: f64,
    recipient: &str,
    artifacts_path: &str,
    skip_confirm: bool,
) -> Result<()> {
    let _recipient_pubkey = Pubkey::from_str(recipient)
        .map_err(|_| anyhow!("Invalid recipient address"))?;

    println!("{}", style("⚡ Anonymous Transfer").bold());
    println!("{}", style("─".repeat(40)).dim());
    println!("  Amount:     {} SOL", style(format!("{:.4}", amount)).green());
    println!("  Recipient:  {}", style(recipient).cyan());
    println!("  From:       {}", style(keypair.pubkey().to_string()).dim());
    println!();
    println!("{}", style("  This will deposit and immediately withdraw to recipient.").dim());
    println!("{}", style("  No on-chain link between you and recipient!").dim());
    println!();

    if !skip_confirm {
        if !Confirm::new()
            .with_prompt("Proceed with anonymous transfer?")
            .default(true)
            .interact()?
        {
            println!("{}", style("Cancelled").red());
            return Ok(());
        }
    }

    // Step 1: Deposit
    println!();
    println!("{}", style("Step 1/2: Depositing...").bold());
    cmd_deposit(client, keypair, amount, artifacts_path, true).await?;

    // Wait for transaction confirmation before querying tree
    println!("{}", style("Waiting for confirmation...").dim());
    tokio::time::sleep(Duration::from_secs(10)).await;

    // Step 2: Withdraw to recipient
    println!();
    println!("{}", style("Step 2/2: Withdrawing to recipient...").bold());
    
    // Get latest note
    let store = NoteStore::load()?;
    let latest_note = store
        .notes
        .iter()
        .filter(|n| n.status == "deposited")
        .last()
        .ok_or_else(|| anyhow!("No deposited note found"))?;

    cmd_withdraw(
        client,
        keypair,
        recipient,
        Some(latest_note.id.clone()),
        artifacts_path,
        true,
    )
    .await?;

    println!();
    println!("{}", style("✅ Anonymous transfer complete!").green().bold());
    println!();
    println!("{}", style("🔐 Privacy achieved:").cyan().bold());
    println!("   • No on-chain link between you and recipient");
    println!("   • Transaction passed through ZK privacy pool");
    println!("   • Recipient could be from any pool depositor");
    println!();

    Ok(())
}

async fn cmd_notes(action: Option<NotesAction>) -> Result<()> {
    let action = action.unwrap_or(NotesAction::List);

    match action {
        NotesAction::List => {
            let store = NoteStore::load()?;

            println!("{}", style("📝 My Notes").bold());
            println!("{}", style("─".repeat(50)).dim());

            if store.notes.is_empty() {
                println!("  No notes found. Use 'privacy deposit' first.");
                return Ok(());
            }

            for note in &store.notes {
                let status_style = match note.status.as_str() {
                    "deposited" => style(&note.status).green(),
                    "withdrawn" => style(&note.status).dim(),
                    _ => style(&note.status).yellow(),
                };

                println!(
                    "  {} │ {} SOL │ {}",
                    style(&note.id).cyan(),
                    style(format!("{:.4}", note.amount as f64 / 1e9)).white(),
                    status_style
                );
            }

            println!();

            let available: u64 = store
                .notes
                .iter()
                .filter(|n| n.status == "deposited")
                .map(|n| n.amount)
                .sum();

            println!(
                "  Available: {} SOL",
                style(format!("{:.4}", available as f64 / 1e9)).green()
            );
            println!();
        }

        NotesAction::Export { file } => {
            let store = NoteStore::load()?;
            store.export(&file)?;
            println!(
                "{} Notes exported to {}",
                style("✅").green(),
                style(&file).cyan()
            );
        }

        NotesAction::Import { file } => {
            let mut store = NoteStore::load()?;
            let count = store.import(&file)?;
            println!(
                "{} Imported {} notes from {}",
                style("✅").green(),
                style(count).yellow(),
                style(&file).cyan()
            );
        }

        NotesAction::Delete { id } => {
            let mut store = NoteStore::load()?;
            if store.delete(&id) {
                println!("{} Note {} deleted", style("✅").green(), style(&id).cyan());
            } else {
                println!("{} Note {} not found", style("❌").red(), style(&id).cyan());
            }
        }
    }

    Ok(())
}

async fn cmd_info(client: &RpcClient, keypair: &Keypair) -> Result<()> {
    let config = PoolConfig::default();

    println!("{}", style("ℹ️  Program Info").bold());
    println!("{}", style("─".repeat(50)).dim());
    println!("  Program ID:     {}", style(PROGRAM_ID).cyan());
    println!("  Tree Account:   {}", style(config.tree_account.to_string()).dim());
    println!("  Global Config:  {}", style(config.global_config.to_string()).dim());
    println!("  Pool Vault:     {}", style(config.pool_vault.to_string()).dim());
    println!();
    println!("{}", style("👛 Wallet").bold());
    println!("{}", style("─".repeat(50)).dim());
    println!("  Address:  {}", style(keypair.pubkey().to_string()).cyan());

    let balance = client.get_balance(&keypair.pubkey())?;
    println!(
        "  Balance:  {} SOL",
        style(format!("{:.4}", balance as f64 / 1e9)).green()
    );
    println!();

    Ok(())
}

/// Fetch commitments from on-chain transaction history
fn fetch_commitments_from_chain(
    client: &RpcClient,
    config: &PoolConfig,
) -> Result<Vec<ark_bn254::Fr>> {
    use solana_client::rpc_config::RpcTransactionConfig;
    use solana_sdk::commitment_config::CommitmentConfig;
    use solana_transaction_status::UiTransactionEncoding;

    let signatures = client.get_signatures_for_address(&config.tree_account)?;

    let mut commitments = Vec::new();
    let discriminator = [217u8, 149, 130, 143, 221, 52, 252, 119];

    for sig_info in signatures.iter().rev() {
        let sig = sig_info.signature.parse().ok();
        if sig.is_none() {
            continue;
        }

        let tx_result = client.get_transaction_with_config(
            &sig.unwrap(),
            RpcTransactionConfig {
                encoding: Some(UiTransactionEncoding::Base64),
                commitment: Some(CommitmentConfig::confirmed()),
                max_supported_transaction_version: Some(0),
            },
        );

        if let Ok(tx) = tx_result {
            if let Some(meta) = tx.transaction.meta {
                if meta.err.is_some() {
                    continue;
                }
            }

            // Parse transaction to extract commitments
            // This is simplified - in production you'd parse the full tx
            if let Some(tx_data) = tx.transaction.transaction.decode() {
                for ix in tx_data.message.instructions() {
                    let data = ix.data.as_slice();
                    if data.len() >= 424 && data[0..8] == discriminator {
                        // commitment1 at offset 360, commitment2 at offset 392
                        let c1_bytes = &data[360..392];
                        let c2_bytes = &data[392..424];

                        if let (Ok(c1), Ok(c2)) = (
                            bytes_to_fr(c1_bytes),
                            bytes_to_fr(c2_bytes),
                        ) {
                            commitments.push(c1);
                            commitments.push(c2);
                        }
                    }
                }
            }
        }
    }

    Ok(commitments)
}

fn bytes_to_fr(bytes: &[u8]) -> Result<ark_bn254::Fr> {
    use ark_ff::PrimeField;
    if bytes.len() != 32 {
        return Err(anyhow!("Invalid length"));
    }
    // Convert from big-endian
    let mut le_bytes = bytes.to_vec();
    le_bytes.reverse();
    Ok(ark_bn254::Fr::from_le_bytes_mod_order(&le_bytes))
}
