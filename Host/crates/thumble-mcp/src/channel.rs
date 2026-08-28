//! Transport seam between the MCP tool handlers and the Thumble Host
//! control surface.
//!
//! The unix control socket remains the default host channel. The relay
//! transport introduced for remote MCP connectors reuses this seam with a
//! channel that is already multiplexed locally; no tool handler is aware of
//! which transport is in use.

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;

use thumble_host::control::{send_request, ControlRequest, ControlResponse};

pub type BoxedHostRequestFuture<'a> =
    Pin<Box<dyn Future<Output = Result<ControlResponse, String>> + Send + 'a>>;

/// A transport to the authoritative Thumble Host control surface.
pub trait HostChannel: Send + Sync + 'static {
    fn request(&self, request: ControlRequest) -> BoxedHostRequestFuture<'_>;
}

/// The default channel: the user-only host unix control socket.
#[derive(Debug, Clone)]
pub struct UnixHostChannel {
    socket: PathBuf,
}

impl UnixHostChannel {
    pub fn new(socket: PathBuf) -> Self {
        Self { socket }
    }
}

impl HostChannel for UnixHostChannel {
    fn request(&self, request: ControlRequest) -> BoxedHostRequestFuture<'_> {
        let socket = self.socket.clone();
        Box::pin(async move { send_request(&socket, &request).await })
    }
}

/// Convenience alias used by [`crate::server::ThumbleMcp`].
pub type SharedHostChannel = Arc<dyn HostChannel>;

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use thumble_host::control::{
        bind_control_socket, remove_control_socket, serve_control, ControlHandler, ControlResponse,
    };
    use tokio::sync::watch;

    struct EchoStatus;

    impl ControlHandler for EchoStatus {
        fn handle(&self, request: ControlRequest) -> ControlResponse {
            match request {
                ControlRequest::ConfigurationStatus => {
                    let mut response = ControlResponse::success();
                    response.configuration = None;
                    response
                }
                _ => ControlResponse::success(),
            }
        }
    }

    #[tokio::test]
    async fn unix_channel_reaches_a_bound_control_socket() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = directory.path().join("control.sock");
        let listener = bind_control_socket(&socket).await.unwrap();
        let (trigger, shutdown) = watch::channel(false);
        tokio::spawn(serve_control(listener, Arc::new(EchoStatus), shutdown));
        let channel = UnixHostChannel::new(socket.clone());
        let response = channel.request(ControlRequest::Status).await;
        assert!(response.is_ok(), "expected a response: {response:?}");
        let _ = trigger.send(true);
        remove_control_socket(&socket);
    }

    #[tokio::test]
    async fn unix_channel_fails_closed_on_missing_socket() {
        let channel = UnixHostChannel::new(PathBuf::from("/nonexistent/thumble-control.sock"));
        let error = channel
            .request(ControlRequest::Status)
            .await
            .expect_err("expected failure for missing socket");
        assert!(error.contains("connect"), "unexpected error: {error}");
    }
}
