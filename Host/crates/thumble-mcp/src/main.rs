use clap::Parser;
use futures::StreamExt;
use rmcp::service::{RxJsonRpcMessage, TxJsonRpcMessage};
use rmcp::transport::async_rw::JsonRpcMessageCodec;
use rmcp::{RoleServer, ServiceExt};
use std::path::PathBuf;
use thumble_host::paths::HostPaths;
use thumble_mcp::{environment_allows_input_with_legacy, ThumbleMcp};
use tokio_util::codec::{FramedRead, FramedWrite, LinesCodec};

const INPUT_ENV: &str = "THUMBLE_MCP_ALLOW_INPUT";
const LEGACY_INPUT_ENV: &str = "POCKETPAD_MCP_ALLOW_INPUT";
const CONFIG_WRITE_ENV: &str = "THUMBLE_MCP_ALLOW_CONFIG_WRITE";
const LEGACY_CONFIG_WRITE_ENV: &str = "POCKETPAD_MCP_ALLOW_CONFIG_WRITE";
const MAXIMUM_ORDINARY_MCP_REQUEST_BYTES: usize = 256 * 1024;
// Covers base64 for the 16 MiB decoded source budget plus bounded edit metadata.
// This applies only to local stdio.
const MAXIMUM_MCP_REQUEST_BYTES: usize = 24 * 1024 * 1024;

fn decode_stdio_request(data: &[u8]) -> Result<RxJsonRpcMessage<RoleServer>, &'static str> {
    if data.len() > MAXIMUM_MCP_REQUEST_BYTES {
        return Err("oversized request");
    }
    let value: serde_json::Value =
        thumble_protocol::decode_unique_json(data).map_err(|_| "ambiguous or invalid request")?;
    let source_update = value.get("method").and_then(serde_json::Value::as_str)
        == Some("tools/call")
        && value
            .get("params")
            .and_then(|params| params.get("name"))
            .and_then(serde_json::Value::as_str)
            == Some("update_controller_design");
    if data.len() > MAXIMUM_ORDINARY_MCP_REQUEST_BYTES && !source_update {
        return Err("oversized ordinary request");
    }
    serde_json::from_value(value).map_err(|_| "invalid request")
}

#[derive(Debug, Parser)]
#[command(
    name = "thumble-mcp",
    version,
    about = "Local stdio MCP adapter for Thumble Host"
)]
struct Cli {
    /// Override the Thumble Host user-only control socket.
    #[arg(long, value_name = "PATH")]
    control_socket: Option<PathBuf>,

    /// Permit the press_control tool. Disabled by default.
    #[arg(long)]
    allow_input: bool,

    /// Permit revision-checked save_configuration_draft commits. Disabled by default.
    #[arg(long)]
    allow_config_write: bool,
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("thumble-mcp stopped: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let cli = Cli::parse();
    let paths = HostPaths::discover().map_err(|error| format!("discover host paths: {error}"))?;
    let control_socket = cli.control_socket.unwrap_or(paths.control_socket);
    let canonical_input = std::env::var_os(INPUT_ENV);
    let legacy_input = std::env::var_os(LEGACY_INPUT_ENV);
    let allow_input = cli.allow_input
        || environment_allows_input_with_legacy(
            canonical_input.as_deref(),
            legacy_input.as_deref(),
        );
    let canonical_config_write = std::env::var_os(CONFIG_WRITE_ENV);
    let legacy_config_write = std::env::var_os(LEGACY_CONFIG_WRITE_ENV);
    let allow_config_write = cli.allow_config_write
        || environment_allows_input_with_legacy(
            canonical_config_write.as_deref(),
            legacy_config_write.as_deref(),
        );

    eprintln!(
        "thumble-mcp starting transport=stdio input={} config-write={}",
        if allow_input { "enabled" } else { "disabled" },
        if allow_config_write {
            "enabled"
        } else {
            "disabled"
        }
    );
    let input = FramedRead::new(
        tokio::io::stdin(),
        LinesCodec::new_with_max_length(MAXIMUM_MCP_REQUEST_BYTES),
    )
    .filter_map(|result| {
        futures::future::ready(match result {
            Ok(line) => match decode_stdio_request(line.as_bytes()) {
                Ok(message) => Some(message),
                Err(_) => {
                    eprintln!("thumble-mcp rejected an ambiguous or invalid request");
                    None
                }
            },
            Err(_) => {
                eprintln!("thumble-mcp rejected an invalid or oversized request");
                None
            }
        })
    });
    let output = FramedWrite::new(
        tokio::io::stdout(),
        JsonRpcMessageCodec::<TxJsonRpcMessage<RoleServer>>::default(),
    );
    let service = ThumbleMcp::new(control_socket, allow_input, allow_config_write)
        .serve((output, input))
        .await
        .map_err(|error| format!("start MCP stdio service: {error}"))?;
    service
        .waiting()
        .await
        .map_err(|error| format!("serve MCP stdio session: {error}"))?;
    eprintln!("thumble-mcp stopped transport=stdio");
    Ok(())
}

#[cfg(test)]
mod stdio_request_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn large_source_updates_preserve_the_ordinary_request_limit() {
        let data = "A".repeat(MAXIMUM_ORDINARY_MCP_REQUEST_BYTES + 1);
        let mut request = json!({"jsonrpc":"2.0","id":1,"method":"tools/call",
            "params":{"name":"update_controller_design","arguments":{
                "workspacePath":"/private/tmp/design","expectedRevision":1,
                "edits":[{"path":"sources/texture.png","data":data}]}}});
        assert!(decode_stdio_request(&serde_json::to_vec(&request).unwrap()).is_ok());
        request["params"]["name"] = json!("review_controller_design");
        assert_eq!(
            decode_stdio_request(&serde_json::to_vec(&request).unwrap()).unwrap_err(),
            "oversized ordinary request"
        );
    }

    #[test]
    fn update_classification_rejects_ambiguous_keys_and_absolute_overflow() {
        let duplicate = br#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_controller_design","\u006eame":"review_controller_design","arguments":{}}}"#;
        assert_eq!(
            decode_stdio_request(duplicate).unwrap_err(),
            "ambiguous or invalid request"
        );
        assert_eq!(
            decode_stdio_request(&vec![b' '; MAXIMUM_MCP_REQUEST_BYTES + 1]).unwrap_err(),
            "oversized request"
        );
        assert!(decode_stdio_request(br#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).is_ok());
    }
}
