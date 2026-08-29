//! Test-only Phase 4 backup/restore fixture helper.
//!
//! The seed credential is written only to the caller-selected receipt file.
//! This program deliberately never prints the receipt or share token.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thumble_builder::{BuilderSession, BuilderTemplate};
use thumble_gateway::builder_store::BuilderEmissionResult;
use thumble_gateway::store::Store;

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Receipt {
    #[serde(rename = "artifactID")]
    artifact_id: String,
    share_token: String,
    hash: String,
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

fn usage() -> String {
    "usage: phase4_seed seed <database> <secret> <receipt.json> | verify <database> <secret> <receipt.json>".to_owned()
}

fn seed(database: &Path, secret: &str, output: &Path) -> Result<(), String> {
    if output.exists() {
        return Err("receipt output already exists".to_owned());
    }
    let store = Store::open(database, secret)?;
    let builder = store.create_builder_principal("Phase 4 restore fixture")?;
    let started_at = now();
    let mut session =
        BuilderSession::begin("8d28b43a-a646-4f85-9a78-0bd98145cd18", started_at, 3600)
            .map_err(|error| error.to_string())?;
    let created = store
        .create_builder_workspace(&builder, &session)
        .map_err(|error| error.to_string())?;
    session
        .install_template(
            "9c814bc5-42f0-4529-8ee6-16f3f03503ea",
            session.revision(),
            BuilderTemplate::Snes,
            Some("Phase 4 Restore Fixture"),
            now(),
        )
        .map_err(|error| error.to_string())?;
    let saved = store
        .save_builder_workspace(
            &builder,
            created.session.revision(),
            created.storage_generation,
            &session,
        )
        .map_err(|error| error.to_string())?;
    if saved.storage_generation <= created.storage_generation {
        return Err("workspace storage generation did not advance".to_owned());
    }
    let emission = session
        .emit_artifact(session.revision(), now())
        .map_err(|error| error.to_string())?;
    let handoff = session
        .mark_emitted(session.revision(), now())
        .map_err(|error| error.to_string())?;
    let result = store
        .emit_builder_artifact(
            &builder,
            &session,
            session.revision(),
            saved.storage_generation,
            &emission,
            &handoff,
        )
        .map_err(|error| error.to_string())?;
    let (artifact, share) = match result {
        BuilderEmissionResult::Emitted { artifact, share } => (artifact, share),
        BuilderEmissionResult::Replayed { .. } => {
            return Err("fresh fixture unexpectedly replayed an emission".to_owned())
        }
    };
    let receipt = Receipt {
        artifact_id: artifact.artifact_id,
        share_token: share.share_token,
        hash: artifact.content_hash,
    };
    let bytes = serde_json::to_vec(&receipt).map_err(|error| error.to_string())?;
    std::fs::write(output, bytes).map_err(|error| format!("write receipt: {error}"))
}

fn verify(database: &Path, secret: &str, receipt_path: &Path) -> Result<(), String> {
    let bytes = std::fs::read(receipt_path).map_err(|error| format!("read receipt: {error}"))?;
    let receipt: Receipt =
        serde_json::from_slice(&bytes).map_err(|error| format!("decode receipt: {error}"))?;
    let store = Store::open(database, secret)?;
    let shared = store
        .lookup_builder_share(&receipt.artifact_id, &receipt.share_token)
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "seeded share is unavailable".to_owned())?;
    if shared.content_hash != receipt.hash {
        return Err("seeded share hash does not match receipt".to_owned());
    }

    // Locate only the receipt's exact source row, then exercise the public
    // principal-scoped tombstone replay API. No listing data or credential is
    // emitted by the helper.
    let connection = rusqlite::Connection::open(database)
        .map_err(|error| format!("open verification database: {error}"))?;
    let source: (String, String, i64) = connection
        .query_row(
            "SELECT principal_id, source_session_id, source_revision
             FROM builder_artifacts WHERE artifact_id = ?1 AND content_hash = ?2",
            rusqlite::params![receipt.artifact_id, receipt.hash],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .map_err(|error| format!("locate seeded emission: {error}"))?;
    drop(connection);
    let replay = store
        .replay_builder_emission(&source.0, &source.1, source.2 as u64)
        .map_err(|error| error.to_string())?;
    let (artifact, share) = match replay {
        BuilderEmissionResult::Replayed { artifact, share } => (artifact, share),
        BuilderEmissionResult::Emitted { .. } => {
            return Err("terminal emission replay returned a fresh emission".to_owned())
        }
    };
    if artifact.artifact_id != receipt.artifact_id
        || artifact.content_hash != receipt.hash
        || share.share_token != receipt.share_token
    {
        return Err("terminal emission/tombstone replay changed the receipt".to_owned());
    }
    Ok(())
}

fn run() -> Result<(), String> {
    let mut arguments = std::env::args_os().skip(1);
    let mode = arguments.next().ok_or_else(usage)?;
    let database = PathBuf::from(arguments.next().ok_or_else(usage)?);
    let secret = arguments
        .next()
        .ok_or_else(usage)?
        .into_string()
        .map_err(|_| "secret must be UTF-8".to_owned())?;
    let receipt = PathBuf::from(arguments.next().ok_or_else(usage)?);
    if arguments.next().is_some() {
        return Err(usage());
    }
    match mode.to_str() {
        Some("seed") => seed(&database, &secret, &receipt),
        Some("verify") => verify(&database, &secret, &receipt),
        _ => Err(usage()),
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("phase4 fixture helper failed: {error}");
        std::process::exit(1);
    }
}
