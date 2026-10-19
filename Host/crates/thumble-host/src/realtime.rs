//! Session-scoped UDP authentication. Input sequencing remains owned by HostCore.
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use thumble_core::ConnectionId;
use thumble_protocol::{ControllerMessage, ControllerMessageType};

pub(crate) const MAXIMUM_DATAGRAM_BYTES: usize = 8 * 1024;

#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RealtimeStatus {
    pub enabled: bool,
    pub authenticated: bool,
    pub authenticated_hellos: u64,
    pub received_inputs: u64,
    pub rejected_datagrams: u64,
    pub udp_accepted_inputs: u64,
    pub websocket_accepted_inputs: u64,
}

// Deliberately no Debug/Serialize: the short-lived bearer token is private.
struct Session {
    connection: ConnectionId,
    token: String,
    peer: Option<SocketAddr>,
}

#[derive(Default)]
pub(crate) struct Realtime {
    session: Option<Session>,
    pub status: RealtimeStatus,
}

impl Realtime {
    pub fn accept(&mut self, connection: ConnectionId, token: String) {
        self.session = Some(Session {
            connection,
            token,
            peer: None,
        });
        self.status.authenticated = false;
    }

    pub fn retire(&mut self, connection: ConnectionId) {
        if self
            .session
            .as_ref()
            .is_some_and(|s| s.connection == connection)
        {
            self.clear();
        }
    }

    pub fn clear(&mut self) {
        self.session = None;
        self.status.authenticated = false;
    }

    pub fn route(&mut self, peer: SocketAddr, message: &ControllerMessage) -> Option<ConnectionId> {
        let Some(session) = self.session.as_mut() else {
            self.status.rejected_datagrams += 1;
            return None;
        };
        if message.message_type == ControllerMessageType::Hello {
            if message
                .realtime_token
                .as_deref()
                .is_some_and(|token| equal_token(token, &session.token))
            {
                session.peer = Some(peer);
                self.status.authenticated = true;
                self.status.authenticated_hellos += 1;
            } else {
                self.status.rejected_datagrams += 1;
            }
            return None;
        }
        if session.peer != Some(peer)
            || !matches!(
                message.message_type,
                ControllerMessageType::Button
                    | ControllerMessageType::ElementInput
                    | ControllerMessageType::Pointer
                    | ControllerMessageType::GamepadAnalog
                    | ControllerMessageType::ReleaseAll
                    | ControllerMessageType::Heartbeat
            )
            || message.input_protocol_version != Some(3)
        {
            self.status.rejected_datagrams += 1;
            return None;
        }
        self.status.received_inputs += 1;
        Some(session.connection)
    }
}

fn equal_token(left: &str, right: &str) -> bool {
    left.len() == right.len()
        && left
            .bytes()
            .zip(right.bytes())
            .fold(0, |diff, (a, b)| diff | (a ^ b))
            == 0
}
