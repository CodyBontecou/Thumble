# syntax=docker/dockerfile:1
FROM rust:1.88-slim AS builder

WORKDIR /build
COPY Host/Cargo.toml Host/Cargo.lock ./
COPY Host/crates ./crates
# thumble-builder embeds the template/spec/artifact fixtures at compile time.
COPY Host/fixtures ./fixtures
RUN cargo build --release --locked -p thumble-gateway

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gzip sqlite3 && \
    rm -rf /var/lib/apt/lists/* && mkdir -p /data
COPY --from=builder /build/target/release/thumble-gateway /usr/local/bin/thumble-gateway
COPY Host/crates/thumble-gateway/backup.sh /usr/local/bin/thumble-gateway-backup
COPY Host/crates/thumble-gateway/start.sh /usr/local/bin/start-thumble-gateway
RUN chmod 0755 /usr/local/bin/thumble-gateway /usr/local/bin/thumble-gateway-backup /usr/local/bin/start-thumble-gateway

# Persistent SQLite lives on the mounted volume. Fly volumes mount root-owned;
# the process runs as the isolated Machine root user so the volume is writable.
ENV THUMBLE_GATEWAY_DB=/data/thumble-gateway.db \
    THUMBLE_GATEWAY_BIND=0.0.0.0:8080
VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/start-thumble-gateway"]
