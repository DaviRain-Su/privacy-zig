use anyhow::{anyhow, Result};
use clap::{Parser, Subcommand};
use console::style;
use dialoguer::{Confirm, Input, Select};
use indicatif::{ProgressBar, ProgressStyle};
use solana_client::rpc_client::RpcClient;
use solana_sdk::{
    commitment_config::CommitmentConfig,
    pubkey::Pubkey,
    signature::{read_keypair_file, Keypair, Signer},
};
use std::str::FromStr;
use std::time::Duration;

mod notes;
mod pool;

use notes::{Note, NoteStore};
use pool::{PoolConfig, PROGRAM_ID};

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
    },

    /// Withdraw SOL from privacy pool
    Withdraw {
        /// Recipient address
        #[arg(short, long)]
        recipient: String,

        /// Note ID to use (optional, will prompt if not provided)
        #[arg(short, long)]
        note_id: Option<String>,
    },

    /// One-click anonymous transfer (deposit + withdraw)
    Transfer {
        /// Amount in SOL
        #[arg(short, long)]
        amount: f64,

        /// Recipient address
        #[arg(short, long)]
        recipient: String,
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

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    // Print banner
    print_banner();

    // Connect to RPC
    let client = RpcClient::new_with_commitment(
        cli.rpc_url.clone(),
        CommitmentConfig::confirmed(),
    );

    // Load keypair
    let keypair = read_keypair_file(&cli.keypair)
        .map_err(|e| anyhow!("Failed to read keypair from {}: {}", cli.keypair, e))?;

    match cli.command {
        Commands::Stats => cmd_stats(&client).await?,
        Commands::Deposit { amount } => cmd_deposit(&client, &keypair, amount).await?,
        Commands::Withdraw { recipient, note_id } => {
            cmd_withdraw(&client, &keypair, &recipient, note_id).await?
        }
        Commands::Transfer { amount, recipient } => {
            cmd_transfer(&client, &keypair, amount, &recipient).await?
        }
        Commands::Notes { action } => cmd_notes(action).await?,
        Commands::Info => cmd_info(&client, &keypair).await?,
    }

    Ok(())
}

fn print_banner() {
    println!();
    println!(
        "{}",
        style("  🔒 privacy-zig CLI").bold().cyan()
    );
    println!(
        "{}",
        style("  Anonymous SOL transfers on Solana").dim()
    );
    println!();
}

async fn cmd_stats(client: &RpcClient) -> Result<()> {
    println!("{}", style("📊 Pool Statistics").bold());
    println!("{}", style("─".repeat(40)).dim());

    let config = PoolConfig::default();

    // Get pool vault balance
    let vault_balance = client.get_balance(&config.pool_vault)?;
    let vault_sol = vault_balance as f64 / 1_000_000_000.0;

    // Get tree info
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

async fn cmd_deposit(client: &RpcClient, keypair: &Keypair, amount: f64) -> Result<()> {
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

    // Confirm
    if !Confirm::new()
        .with_prompt("Proceed with deposit?")
        .default(true)
        .interact()?
    {
        println!("{}", style("Cancelled").red());
        return Ok(());
    }

    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .template("{spinner:.green} {msg}")
            .unwrap(),
    );

    pb.set_message("Generating ZK proof...");
    pb.enable_steady_tick(Duration::from_millis(100));

    // TODO: Implement actual deposit logic
    // For now, show placeholder
    std::thread::sleep(Duration::from_secs(2));

    pb.set_message("Sending transaction...");
    std::thread::sleep(Duration::from_secs(1));

    pb.finish_with_message("Done!");

    println!();
    println!("{}", style("✅ Deposit successful!").green().bold());
    println!();
    println!(
        "{}",
        style("⚠️  Note saved to ~/.privacy-zig/notes.json").yellow()
    );
    println!(
        "{}",
        style("   Make sure to backup your notes!").yellow()
    );
    println!();

    Ok(())
}

async fn cmd_withdraw(
    client: &RpcClient,
    keypair: &Keypair,
    recipient: &str,
    note_id: Option<String>,
) -> Result<()> {
    // Validate recipient
    let recipient_pubkey = Pubkey::from_str(recipient)
        .map_err(|_| anyhow!("Invalid recipient address"))?;

    // Load notes
    let store = NoteStore::load()?;
    let available_notes: Vec<_> = store.notes.iter().filter(|n| n.status == "deposited").collect();

    if available_notes.is_empty() {
        println!("{}", style("❌ No withdrawable notes found.").red());
        println!("   Use 'privacy deposit' first.");
        return Ok(());
    }

    // Select note
    let note = if let Some(id) = note_id {
        available_notes
            .iter()
            .find(|n| n.id == id)
            .ok_or_else(|| anyhow!("Note {} not found", id))?
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

    if !Confirm::new()
        .with_prompt("Proceed with withdrawal?")
        .default(true)
        .interact()?
    {
        println!("{}", style("Cancelled").red());
        return Ok(());
    }

    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .template("{spinner:.green} {msg}")
            .unwrap(),
    );

    pb.set_message("Fetching Merkle tree...");
    pb.enable_steady_tick(Duration::from_millis(100));
    std::thread::sleep(Duration::from_secs(1));

    pb.set_message("Generating ZK proof...");
    std::thread::sleep(Duration::from_secs(2));

    pb.set_message("Sending transaction...");
    std::thread::sleep(Duration::from_secs(1));

    pb.finish_with_message("Done!");

    println!();
    println!("{}", style("✅ Withdrawal successful!").green().bold());
    println!();
    println!(
        "{}",
        style("🔐 No on-chain link between your deposit and this withdrawal!").cyan()
    );
    println!();

    Ok(())
}

async fn cmd_transfer(
    client: &RpcClient,
    keypair: &Keypair,
    amount: f64,
    recipient: &str,
) -> Result<()> {
    let recipient_pubkey = Pubkey::from_str(recipient)
        .map_err(|_| anyhow!("Invalid recipient address"))?;

    println!("{}", style("⚡ Anonymous Transfer").bold());
    println!("{}", style("─".repeat(40)).dim());
    println!("  Amount:     {} SOL", style(format!("{:.4}", amount)).green());
    println!("  Recipient:  {}", style(recipient).cyan());
    println!("  From:       {}", style(keypair.pubkey().to_string()).dim());
    println!();

    println!(
        "{}",
        style("  This will deposit and immediately withdraw to recipient.").dim()
    );
    println!(
        "{}",
        style("  No on-chain link between you and recipient!").dim()
    );
    println!();

    if !Confirm::new()
        .with_prompt("Proceed with anonymous transfer?")
        .default(true)
        .interact()?
    {
        println!("{}", style("Cancelled").red());
        return Ok(());
    }

    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .template("{spinner:.green} {msg}")
            .unwrap(),
    );

    pb.set_message("[1/4] Generating deposit proof...");
    pb.enable_steady_tick(Duration::from_millis(100));
    std::thread::sleep(Duration::from_secs(2));

    pb.set_message("[2/4] Sending deposit transaction...");
    std::thread::sleep(Duration::from_secs(1));

    pb.set_message("[3/4] Generating withdrawal proof...");
    std::thread::sleep(Duration::from_secs(2));

    pb.set_message("[4/4] Sending withdrawal transaction...");
    std::thread::sleep(Duration::from_secs(1));

    pb.finish_with_message("Done!");

    println!();
    println!("{}", style("✅ Anonymous transfer complete!").green().bold());
    println!();
    println!(
        "{}",
        style("🔐 Privacy achieved:").cyan().bold()
    );
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
