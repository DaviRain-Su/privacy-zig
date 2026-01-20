use anyhow::Result;
use axum::{
    extract::State,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde::{Deserialize, Serialize};
use solana_client::rpc_client::RpcClient;
use solana_sdk::{
    commitment_config::CommitmentConfig,
    compute_budget::ComputeBudgetInstruction,
    instruction::{AccountMeta, Instruction},
    pubkey::Pubkey,
    signature::Keypair,
    signer::Signer,
    system_program,
    transaction::Transaction,
};
use std::{str::FromStr, sync::Arc};
use tower_http::cors::{Any, CorsLayer};
use tracing::{info, error};

// Pool configuration
const PROGRAM_ID: &str = "9A6fck3xNW2C6vwwqM4i1f4GeYpieuB7XKpF1YFduT6h";
const TREE_ACCOUNT: &str = "4EGnTF2XfKDTBAszzoqQLe4zbmiURkWtkYQGnj99GiJf";
const GLOBAL_CONFIG: &str = "7RUeHfhA6L7BUrmt9ZK7SJ9rmTMkD8qjjJgHRrUEGMq9";
const POOL_VAULT: &str = "7nAKNHQwTeaybrnX6y3c3fLDL3qzQ3A6FGwMwH1LPc8q";
// Use relayer address as fee_recipient to avoid exposing user address
const FEE_RECIPIENT: &str = "FcuLoWBhZ8bNQRsSgGhH5NCJJbqK5uhHMZR6V21kyTgS";

struct AppState {
    client: RpcClient,
    relayer_keypair: Keypair,
    program_id: Pubkey,
    tree_account: Pubkey,
    global_config: Pubkey,
    pool_vault: Pubkey,
    fee_recipient: Pubkey,
}

fn env_or_default(key: &str, fallback: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| fallback.to_string())
}

#[derive(Deserialize)]
struct RelayRequest {
    /// Base64-encoded instruction data (proof + public inputs)
    instruction_data: String,
    /// Nullifier 1 bytes (hex)
    nullifier1: String,
    /// Nullifier 2 bytes (hex)
    nullifier2: String,
    /// Recipient address (base58)
    recipient: String,
}

#[derive(Serialize)]
struct RelayResponse {
    success: bool,
    signature: Option<String>,
    error: Option<String>,
}

#[derive(Serialize)]
struct InfoResponse {
    relayer_address: String,
    program_id: String,
    pool_vault: String,
    balance: f64,
}

async fn health() -> &'static str {
    "OK"
}

async fn info(State(state): State<Arc<AppState>>) -> Json<InfoResponse> {
    let balance = state
        .client
        .get_balance(&state.relayer_keypair.pubkey())
        .unwrap_or(0) as f64
        / 1_000_000_000.0;

    Json(InfoResponse {
        relayer_address: state.relayer_keypair.pubkey().to_string(),
        program_id: state.program_id.to_string(),
        pool_vault: state.pool_vault.to_string(),
        balance,
    })
}

async fn relay_withdraw(
    State(state): State<Arc<AppState>>,
    Json(req): Json<RelayRequest>,
) -> (StatusCode, Json<RelayResponse>) {
    info!("Received relay request for recipient: {}", req.recipient);

    // Parse inputs
    let instruction_data = match BASE64.decode(&req.instruction_data) {
        Ok(data) => data,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(RelayResponse {
                    success: false,
                    signature: None,
                    error: Some(format!("Invalid instruction data: {}", e)),
                }),
            );
        }
    };

    let nullifier1 = match hex::decode(&req.nullifier1) {
        Ok(data) => data,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(RelayResponse {
                    success: false,
                    signature: None,
                    error: Some(format!("Invalid nullifier1: {}", e)),
                }),
            );
        }
    };

    let nullifier2 = match hex::decode(&req.nullifier2) {
        Ok(data) => data,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(RelayResponse {
                    success: false,
                    signature: None,
                    error: Some(format!("Invalid nullifier2: {}", e)),
                }),
            );
        }
    };

    let recipient = match Pubkey::from_str(&req.recipient) {
        Ok(pk) => pk,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(RelayResponse {
                    success: false,
                    signature: None,
                    error: Some(format!("Invalid recipient: {}", e)),
                }),
            );
        }
    };

    // Derive nullifier PDAs
    let (nullifier1_pda, _) = Pubkey::find_program_address(
        &[b"nullifier", &nullifier1],
        &state.program_id,
    );
    let (nullifier2_pda, _) = Pubkey::find_program_address(
        &[b"nullifier", &nullifier2],
        &state.program_id,
    );

    // Build transaction with relayer as signer
    // Account order: tree, null1, null2, config, vault, signer, recipient, fee_recipient, system
    let transact_ix = Instruction {
        program_id: state.program_id,
        accounts: vec![
            AccountMeta::new(state.tree_account, false),
            AccountMeta::new(nullifier1_pda, false),
            AccountMeta::new(nullifier2_pda, false),
            AccountMeta::new_readonly(state.global_config, false),
            AccountMeta::new(state.pool_vault, false),
            AccountMeta::new(state.relayer_keypair.pubkey(), true), // relayer signs!
            AccountMeta::new(recipient, false),                     // recipient gets SOL
            AccountMeta::new(state.fee_recipient, false),
            AccountMeta::new_readonly(system_program::id(), false),
        ],
        data: instruction_data,
    };

    let compute_ix = ComputeBudgetInstruction::set_compute_unit_limit(1_400_000);

    let recent_blockhash = match state.client.get_latest_blockhash() {
        Ok(bh) => bh,
        Err(e) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(RelayResponse {
                    success: false,
                    signature: None,
                    error: Some(format!("Failed to get blockhash: {}", e)),
                }),
            );
        }
    };

    let tx = Transaction::new_signed_with_payer(
        &[compute_ix, transact_ix],
        Some(&state.relayer_keypair.pubkey()),
        &[&state.relayer_keypair],
        recent_blockhash,
    );

    // Send transaction
    match state.client.send_and_confirm_transaction(&tx) {
        Ok(sig) => {
            info!("Transaction successful: {}", sig);
            (
                StatusCode::OK,
                Json(RelayResponse {
                    success: true,
                    signature: Some(sig.to_string()),
                    error: None,
                }),
            )
        }
        Err(e) => {
            error!("Transaction failed: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(RelayResponse {
                    success: false,
                    signature: None,
                    error: Some(format!("Transaction failed: {}", e)),
                }),
            )
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    // Load relayer keypair from default location or env
    let keypair_path = std::env::var("RELAYER_KEYPAIR")
        .unwrap_or_else(|_| {
            format!("{}/.config/solana/id.json", std::env::var("HOME").unwrap())
        });
    
    let keypair_data: Vec<u8> = serde_json::from_str(
        &std::fs::read_to_string(&keypair_path)?
    )?;
    let relayer_keypair = Keypair::from_bytes(&keypair_data)?;

    info!("Relayer address: {}", relayer_keypair.pubkey());

    // Connect to testnet
    let client = RpcClient::new_with_commitment(
        "https://api.testnet.solana.com".to_string(),
        CommitmentConfig::confirmed(),
    );

    let balance = client.get_balance(&relayer_keypair.pubkey())?;
    info!("Relayer balance: {} SOL", balance as f64 / 1_000_000_000.0);

    let state = Arc::new(AppState {
        client,
        relayer_keypair,
        program_id: Pubkey::from_str(&env_or_default("PRIVACY_POOL_PROGRAM_ID", PROGRAM_ID)).unwrap(),
        tree_account: Pubkey::from_str(&env_or_default("PRIVACY_POOL_TREE_ACCOUNT", TREE_ACCOUNT)).unwrap(),
        global_config: Pubkey::from_str(&env_or_default("PRIVACY_POOL_GLOBAL_CONFIG", GLOBAL_CONFIG)).unwrap(),
        pool_vault: Pubkey::from_str(&env_or_default("PRIVACY_POOL_POOL_VAULT", POOL_VAULT)).unwrap(),
        fee_recipient: Pubkey::from_str(&env_or_default("PRIVACY_POOL_FEE_RECIPIENT", FEE_RECIPIENT)).unwrap(),
    });

    // Setup CORS
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    // Build router
    let app = Router::new()
        .route("/health", get(health))
        .route("/info", get(info))
        .route("/relay", post(relay_withdraw))
        .layer(cors)
        .with_state(state);

    let port = std::env::var("PORT").unwrap_or_else(|_| "3001".to_string());
    let addr = format!("0.0.0.0:{}", port);
    
    info!("Starting relayer on {}", addr);
    
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}
