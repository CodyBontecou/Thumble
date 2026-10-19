use std::time::Duration;

use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};

/// A known oversized Content-Length must be rejected before reading any body.
/// Uploading the rejected body concurrently races the early response with a TCP
/// reset on macOS. Expect/continue makes the intended header-only probe explicit.
pub async fn assert_oversized_request_rejected(
    base: &str,
    path: &str,
    token: &str,
    content_length: usize,
) {
    tokio::time::timeout(Duration::from_secs(5), async {
        let address = base.strip_prefix("http://").unwrap();
        let mut socket = tokio::net::TcpStream::connect(address).await.unwrap();
        let headers = format!(
            "POST {path} HTTP/1.1\r\nHost: {address}\r\nAuthorization: Bearer {token}\r\n\
             Content-Type: application/json\r\nContent-Length: {content_length}\r\n\
             Expect: 100-continue\r\nConnection: close\r\n\r\n"
        );
        socket.write_all(headers.as_bytes()).await.unwrap();
        let mut status = String::new();
        BufReader::new(socket).read_line(&mut status).await.unwrap();
        assert_eq!(status, "HTTP/1.1 413 Payload Too Large\r\n");
    })
    .await
    .expect("oversized request must receive 413 without uploading its body");
}
