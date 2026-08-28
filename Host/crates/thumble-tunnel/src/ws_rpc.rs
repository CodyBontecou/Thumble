//! WebSocket adapters that expose one rmcp JSON-RPC message per WebSocket
//! frame, usable with rmcp's `SinkStreamTransport` via `service.serve((sink,
//! stream))`.
//!
//! Session frames are Binary; each carries exactly one serialized JSON-RPC
//! message with no newline framing. Control-channel frames are JSON Text
//! messages handled separately by [`crate::protocol::TunnelMessage`].

use futures::{Sink, Stream};
use rmcp::service::{RxJsonRpcMessage, ServiceRole, TxJsonRpcMessage};
use std::marker::PhantomData;
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

/// Concrete socket IO type. The relay client connects over TLS to the hosted
/// gateway; the gateway accepts TCP TLS-terminated upstream traffic.
pub type WsIo = tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>;

/// A WebSocket half that sends one JSON-RPC message per frame.
pub struct WsJsonRpcSink<Role: ServiceRole> {
    inner: futures::stream::SplitSink<WebSocketStream<WsIo>, Message>,
    _role: PhantomData<fn() -> Role>,
}

/// A WebSocket half that yields parsed inbound JSON-RPC messages, skipping
/// control frames and dropping undecodable payloads.
pub struct WsJsonRpcStream<Role: ServiceRole> {
    inner: futures::stream::SplitStream<WebSocketStream<WsIo>>,
    _role: PhantomData<fn() -> Role>,
}

/// Split a WebSocket into an rmcp-compatible sink/stream pair.
pub fn split_json_rpc_ws<Role: ServiceRole>(
    websocket: WebSocketStream<WsIo>,
) -> (WsJsonRpcSink<Role>, WsJsonRpcStream<Role>) {
    use futures::StreamExt;
    let (sink, stream) = websocket.split();
    (
        WsJsonRpcSink {
            inner: sink,
            _role: PhantomData,
        },
        WsJsonRpcStream {
            inner: stream,
            _role: PhantomData,
        },
    )
}

fn encode_error(error: serde_json::Error) -> tokio_tungstenite::tungstenite::Error {
    // Serializing rmcp model types cannot realistically fail; keep a typed
    // error so the transport surfaces it instead of panicking.
    tokio_tungstenite::tungstenite::Error::Io(std::io::Error::new(
        std::io::ErrorKind::InvalidData,
        format!("encode JSON-RPC message: {error}"),
    ))
}

impl<Role: ServiceRole> Sink<TxJsonRpcMessage<Role>> for WsJsonRpcSink<Role> {
    type Error = tokio_tungstenite::tungstenite::Error;

    fn poll_ready(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Sink::poll_ready(Pin::new(&mut self.get_mut().inner), cx)
    }

    fn start_send(self: Pin<&mut Self>, item: TxJsonRpcMessage<Role>) -> Result<(), Self::Error> {
        let encoded = serde_json::to_vec(&item).map_err(encode_error)?;
        if encoded.len() > crate::MAXIMUM_FRAME_BYTES {
            return Err(tokio_tungstenite::tungstenite::Error::Io(
                std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "outbound JSON-RPC message exceeds the tunnel frame cap",
                ),
            ));
        }
        Sink::start_send(
            Pin::new(&mut self.get_mut().inner),
            Message::Binary(encoded.into()),
        )
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Sink::poll_flush(Pin::new(&mut self.get_mut().inner), cx)
    }

    fn poll_close(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Sink::poll_close(Pin::new(&mut self.get_mut().inner), cx)
    }
}

impl<Role: ServiceRole> Stream for WsJsonRpcStream<Role> {
    type Item = RxJsonRpcMessage<Role>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        loop {
            match Pin::new(&mut this.inner).poll_next(cx) {
                Poll::Ready(Some(Ok(message))) => {
                    let bytes = match message {
                        Message::Binary(bytes) => bytes.to_vec(),
                        Message::Text(text) => text.as_str().as_bytes().to_vec(),
                        Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
                        Message::Close(_) => return Poll::Ready(None),
                    };
                    if bytes.len() > crate::MAXIMUM_FRAME_BYTES {
                        eprintln!("thumble tunnel: rejected an oversized JSON-RPC frame");
                        return Poll::Ready(None);
                    }
                    match serde_json::from_slice::<RxJsonRpcMessage<Role>>(&bytes) {
                        Ok(message) => return Poll::Ready(Some(message)),
                        Err(error) => {
                            eprintln!(
                                "thumble tunnel: dropped an undecodable JSON-RPC frame: {error}"
                            );
                            continue;
                        }
                    }
                }
                Poll::Ready(Some(Err(error))) => {
                    eprintln!("thumble tunnel: session websocket failed: {error}");
                    return Poll::Ready(None);
                }
                Poll::Ready(None) => return Poll::Ready(None),
                Poll::Pending => return Poll::Pending,
            }
        }
    }
}

/// Encode one control-channel [`crate::protocol::TunnelMessage`] as a Text
/// frame payload.
pub fn encode_control_message(message: &crate::protocol::TunnelMessage) -> String {
    serde_json::to_string(message).unwrap_or_else(|error| {
        panic!("control frames are always serializable: {error}");
    })
}

/// Decode one inbound control-channel Text frame payload.
pub fn decode_control_message(payload: &[u8]) -> Option<crate::protocol::TunnelMessage> {
    serde_json::from_slice(payload).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rmcp::{
        model::{ClientJsonRpcMessage, PingRequest, RequestId},
        RoleClient,
    };

    fn client_message(id: i64) -> TxJsonRpcMessage<RoleClient> {
        let request = rmcp::model::ClientRequest::PingRequest(PingRequest::default());
        ClientJsonRpcMessage::request(request, RequestId::Number(id))
    }

    #[test]
    fn control_message_codec_round_trips() {
        let message = crate::protocol::TunnelMessage::Ping;
        let encoded = encode_control_message(&message);
        assert_eq!(decode_control_message(encoded.as_bytes()), Some(message));
        assert!(decode_control_message(b"{\"type\":\"nope\"}").is_none());
    }

    #[test]
    fn client_message_serializes_to_a_single_object() {
        let encoded = serde_json::to_vec(&client_message(7)).unwrap();
        assert!(encoded.starts_with(b"{") && encoded.ends_with(b"}"));
        assert!(!encoded.windows(1).any(|w| w == b"\n"));
        let decoded: RxJsonRpcMessage<RoleClient> = serde_json::from_slice(&encoded).unwrap();
        decoded.into_request().unwrap();
    }

    #[tokio::test]
    async fn json_rpc_frames_round_trip_over_a_real_websocket() {
        use futures::{SinkExt, StreamExt};
        use rmcp::model::{RequestId, ServerJsonRpcMessage};
        use rmcp::RoleServer;
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server_task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let websocket =
                tokio_tungstenite::accept_async(tokio_tungstenite::MaybeTlsStream::Plain(stream))
                    .await
                    .unwrap();
            let (mut sink, mut stream) = split_json_rpc_ws::<RoleServer>(websocket);
            let request = stream.next().await.expect("expected a request frame");
            let (_ping, id) = request.into_request().unwrap();
            sink.send(ServerJsonRpcMessage::response(
                rmcp::model::ServerResult::empty(()),
                id,
            ))
            .await
            .unwrap();
        });

        let (stream, _response) = tokio_tungstenite::connect_async(format!("ws://{address}/"))
            .await
            .unwrap();
        let (mut sink, mut stream) = split_json_rpc_ws::<RoleClient>(stream);
        sink.send(client_message(41)).await.unwrap();
        let reply = stream.next().await.expect("expected a response frame");
        let (_result, id) = reply.into_response().unwrap();
        assert_eq!(id, RequestId::Number(41));
        server_task.await.unwrap();
    }
}
