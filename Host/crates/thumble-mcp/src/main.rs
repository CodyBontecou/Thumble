use clap::Parser;
use futures::StreamExt;
use rmcp::model::{ClientRequest, JsonRpcMessage};
use rmcp::service::{RxJsonRpcMessage, TxJsonRpcMessage};
use rmcp::transport::async_rw::JsonRpcMessageCodec;
use rmcp::{RoleServer, ServiceExt};
use std::path::PathBuf;
use thumble_host::paths::HostPaths;
use thumble_mcp::relay::{run_doctor, run_link, run_relay, run_relink, run_revoke, RelayConfig};
use thumble_mcp::{environment_allows_input_with_legacy, ThumbleMcp};
use tokio_util::codec::{FramedRead, FramedWrite, LinesCodec};

const INPUT_ENV: &str = "THUMBLE_MCP_ALLOW_INPUT";
const LEGACY_INPUT_ENV: &str = "POCKETPAD_MCP_ALLOW_INPUT";
const CONFIG_WRITE_ENV: &str = "THUMBLE_MCP_ALLOW_CONFIG_WRITE";
const LEGACY_CONFIG_WRITE_ENV: &str = "POCKETPAD_MCP_ALLOW_CONFIG_WRITE";
const MAXIMUM_MCP_REQUEST_BYTES: usize = 256 * 1024;
const MAXIMUM_MCP_ATTACHMENT_REQUEST_BYTES: usize = 8 * 1024 * 1024;

/// The line codec bounds allocation before JSON parsing. Only the typed local
/// attachment request receives the larger window needed for inline PNG bytes.
fn decode_mcp_request(frame: &str) -> Result<RxJsonRpcMessage<RoleServer>, &'static str> {
    if frame.len() > MAXIMUM_MCP_ATTACHMENT_REQUEST_BYTES {
        return Err("MCP request exceeds the attachment frame limit");
    }
    // Preserve the SDK's leading-BOM compatibility without its parse-error log,
    // which includes the complete request and could expose image payloads.
    let json = frame.strip_prefix('\u{feff}').unwrap_or(frame);
    let message: RxJsonRpcMessage<RoleServer> =
        serde_json::from_str(json).map_err(|_| "invalid MCP request")?;
    let is_attachment = matches!(
        &message,
        JsonRpcMessage::Request(request)
            if matches!(&request.request, ClientRequest::CallToolRequest(call)
                if call.params.name == "attach_game_controller_assets")
    );
    if frame.len() > MAXIMUM_MCP_REQUEST_BYTES && !is_attachment {
        return Err("MCP request exceeds the ordinary frame limit");
    }
    Ok(message)
}

#[derive(Debug, Parser)]
#[command(
    name = "thumble-mcp",
    version,
    about = "Local stdio MCP adapter for Thumble Host (or --relay for remote connectors)"
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

    /// Serve remote MCP sessions through the hosted gateway control tunnel
    /// (e.g. wss://mcp.thumble.app/tunnel) instead of local stdio.
    #[arg(long, value_name = "URL", conflicts_with_all = ["relay_link", "relay_relink", "relay_revoke"])]
    relay: Option<String>,

    /// Complete only the six-digit device-link flow, persist the token, and exit.
    #[arg(long, value_name = "URL", conflicts_with_all = ["relay", "relay_relink", "relay_revoke"])]
    relay_link: Option<String>,

    /// Rotate the device-link token in place. A running relay reloads it.
    #[arg(long, value_name = "URL", conflicts_with_all = ["relay", "relay_link", "relay_revoke"])]
    relay_relink: Option<String>,

    /// Where the gateway device token is persisted. Defaults to the host
    /// state directory.
    #[arg(long, value_name = "PATH")]
    relay_token_file: Option<PathBuf>,

    /// Friendly device name shown on the gateway link page.
    #[arg(long, value_name = "NAME", default_value = "Mac")]
    relay_device_name: String,

    /// Revoke this device at the gateway and delete the local token, then exit.
    #[arg(long, value_name = "URL", conflicts_with_all = ["relay", "relay_link", "relay_relink"])]
    relay_revoke: Option<String>,

    /// Diagnose every local remote-connector prerequisite, then exit.
    #[arg(long, value_name = "URL", conflicts_with_all = ["relay", "relay_link", "relay_relink", "relay_revoke"])]
    relay_doctor: Option<String>,

    /// Emit doctor output as JSON (used by `thumble relay doctor`).
    #[arg(long)]
    json: bool,
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("thumble-mcp stopped: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    // tokio-tungstenite/rustls deliberately leaves provider choice to the
    // application. Install ring explicitly so wss:// relay startup cannot
    // panic when multiple or zero implicit providers are visible.
    let _ = rustls::crypto::ring::default_provider().install_default();
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

    if let Some(link_url) = cli.relay_link.as_ref() {
        let token_file = cli
            .relay_token_file
            .clone()
            .unwrap_or_else(|| paths.state_dir.join("relay-token"));
        let config = RelayConfig {
            relay_url: link_url.clone(),
            token_file,
            device_name: cli.relay_device_name.clone(),
            control_socket: control_socket.clone(),
            allow_input: false,
            allow_config_write: false,
        };
        return run_link(&config).await;
    }

    if let Some(relink_url) = cli.relay_relink {
        let token_file = cli
            .relay_token_file
            .clone()
            .unwrap_or_else(|| paths.state_dir.join("relay-token"));
        let config = RelayConfig {
            relay_url: relink_url,
            token_file,
            device_name: cli.relay_device_name.clone(),
            control_socket: control_socket.clone(),
            allow_input: false,
            allow_config_write: false,
        };
        return run_relink(&config).await;
    }

    if let Some(revoke_url) = cli.relay_revoke {
        let token_file = cli
            .relay_token_file
            .unwrap_or_else(|| paths.state_dir.join("relay-token"));
        let config = RelayConfig {
            relay_url: revoke_url,
            token_file,
            device_name: cli.relay_device_name.clone(),
            control_socket: control_socket.clone(),
            allow_input: false,
            allow_config_write: false,
        };
        return run_revoke(&config).await;
    }

    if let Some(doctor_url) = cli.relay_doctor {
        let token_file = cli
            .relay_token_file
            .clone()
            .unwrap_or_else(|| paths.state_dir.join("relay-token"));
        let config = RelayConfig {
            relay_url: doctor_url,
            token_file,
            device_name: cli.relay_device_name.clone(),
            control_socket: control_socket.clone(),
            allow_input: false,
            allow_config_write: cli.allow_config_write,
        };
        let ready = run_doctor(&config, cli.json).await?;
        if !ready {
            std::process::exit(1);
        }
        return Ok(());
    }

    if let Some(relay_url) = cli.relay {
        let token_file = cli
            .relay_token_file
            .unwrap_or_else(|| paths.state_dir.join("relay-token"));
        let config = RelayConfig {
            relay_url,
            token_file,
            device_name: cli.relay_device_name,
            control_socket,
            allow_input,
            allow_config_write,
        };
        eprintln!(
            "thumble-mcp starting transport=relay input={} config-write={}",
            if allow_input { "enabled" } else { "disabled" },
            if allow_config_write {
                "enabled"
            } else {
                "disabled"
            }
        );
        let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
        let signal_task = tokio::spawn(async move {
            let _ = tokio::signal::ctrl_c().await;
            let _ = shutdown_tx.send(true);
        });
        let outcome = run_relay(config, shutdown_rx).await;
        signal_task.abort();
        match outcome {
            Ok(_) => {
                eprintln!("thumble-mcp stopped transport=relay");
                Ok(())
            }
            Err(error) => Err(error),
        }
    } else {
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
            LinesCodec::new_with_max_length(MAXIMUM_MCP_ATTACHMENT_REQUEST_BYTES),
        )
        .filter_map(|result| {
            let decoded = result
                .map_err(|_| "invalid or oversized MCP frame")
                .and_then(|frame| decode_mcp_request(&frame));
            futures::future::ready(match decoded {
                Ok(message) => Some(message),
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio_util::bytes::BytesMut;
    use tokio_util::codec::Decoder;

    fn tool_request(name: &str, payload_bytes: usize) -> String {
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": name,
                "arguments": {
                    "images": [{"assetID": "ability-q", "pngBase64": "A".repeat(payload_bytes)}]
                }
            }
        })
        .to_string()
    }

    fn framed_request(frame: &str) -> Result<RxJsonRpcMessage<RoleServer>, &'static str> {
        let mut bytes = BytesMut::from(frame.as_bytes());
        bytes.extend_from_slice(b"\n");
        let mut codec = LinesCodec::new_with_max_length(MAXIMUM_MCP_ATTACHMENT_REQUEST_BYTES);
        let line = codec
            .decode(&mut bytes)
            .map_err(|_| "framing rejected request")?
            .ok_or("incomplete request")?;
        decode_mcp_request(&line)
    }

    #[test]
    fn accepts_small_ordinary_request_and_bom() {
        let ping = r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#;
        assert!(framed_request(ping).is_ok());
        assert!(framed_request(&format!("\u{feff}{ping}")).is_ok());
    }

    #[test]
    fn accepts_large_attachment_request_through_bounded_framing() {
        let frame = tool_request("attach_game_controller_assets", MAXIMUM_MCP_REQUEST_BYTES);
        assert!(frame.len() > MAXIMUM_MCP_REQUEST_BYTES);
        assert!(framed_request(&frame).is_ok());
    }

    #[test]
    fn attachment_accepts_exact_hard_frame_limit() {
        let overhead = tool_request("attach_game_controller_assets", 0).len();
        let frame = tool_request(
            "attach_game_controller_assets",
            MAXIMUM_MCP_ATTACHMENT_REQUEST_BYTES - overhead,
        );
        assert_eq!(frame.len(), MAXIMUM_MCP_ATTACHMENT_REQUEST_BYTES);
        assert!(framed_request(&frame).is_ok());
    }

    #[test]
    fn rejects_large_ordinary_tool_request() {
        let frame = tool_request("plan_game_controller", MAXIMUM_MCP_REQUEST_BYTES);
        assert_eq!(
            framed_request(&frame).unwrap_err(),
            "MCP request exceeds the ordinary frame limit"
        );
    }

    #[test]
    fn ordinary_limit_counts_raw_whitespace() {
        let mut frame = r#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.to_owned();
        frame.push_str(&" ".repeat(MAXIMUM_MCP_REQUEST_BYTES - frame.len()));
        assert!(framed_request(&frame).is_ok());
        frame.push(' ');
        assert_eq!(
            framed_request(&frame).unwrap_err(),
            "MCP request exceeds the ordinary frame limit"
        );
    }

    #[test]
    fn rejects_attachment_over_hard_frame_limit_before_parsing() {
        let frame = tool_request(
            "attach_game_controller_assets",
            MAXIMUM_MCP_ATTACHMENT_REQUEST_BYTES,
        );
        assert_eq!(
            framed_request(&frame).unwrap_err(),
            "framing rejected request"
        );
        let mut codec = LinesCodec::new_with_max_length(MAXIMUM_MCP_ATTACHMENT_REQUEST_BYTES);
        let mut unterminated = BytesMut::from(frame.as_bytes());
        assert!(codec.decode(&mut unterminated).is_err());
        assert_eq!(
            decode_mcp_request(&frame).unwrap_err(),
            "MCP request exceeds the attachment frame limit"
        );
    }

    #[test]
    fn malformed_request_error_contains_no_payload() {
        let mut frame = tool_request("attach_game_controller_assets", MAXIMUM_MCP_REQUEST_BYTES);
        frame.pop();
        assert_eq!(framed_request(&frame).unwrap_err(), "invalid MCP request");
    }

    #[test]
    fn larger_window_requires_exact_tool_call_request() {
        let padding = "A".repeat(MAXIMUM_MCP_REQUEST_BYTES);
        let notification = json!({
            "jsonrpc":"2.0", "method":"tools/call",
            "params":{"name":"attach_game_controller_assets", "arguments":{"payload":padding}},
        })
        .to_string();
        assert!(framed_request(&notification).is_err());
        let other_method = json!({
            "jsonrpc":"2.0", "id":1, "method":"other/call",
            "params":{"name":"attach_game_controller_assets", "arguments":{"payload":padding}},
        })
        .to_string();
        assert_eq!(
            framed_request(&other_method).unwrap_err(),
            "MCP request exceeds the ordinary frame limit"
        );
        assert!(framed_request(&tool_request(
            "attach_game_controller_assets_extra",
            MAXIMUM_MCP_REQUEST_BYTES,
        ))
        .is_err());
    }
}
