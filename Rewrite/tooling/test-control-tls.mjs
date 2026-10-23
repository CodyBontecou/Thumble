// Actual Node/OpenSSL -> native Rust TLS/packet interoperability. Loopback and public fixture keys only.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { connect, checkServerIdentity } from "node:tls";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
const executable = fileURLToPath(
  new URL(
    `../native/receiver/target/debug/examples/control_tls_probe${process.platform === "win32" ? ".exe" : ""}`,
    import.meta.url,
  ),
);
const fixture = JSON.parse(
  readFileSync(
    new URL("../packages/fixtures/input-packet-v1.json", import.meta.url),
    "utf8",
  ),
);
const serverName = "thumble-rewrite.local",
  alpn = "thumble-rewrite-control/1";
async function probe(run) {
  const child = spawn(executable, [], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "",
    stderr = "";
  const deadline = setTimeout(() => child.kill(), 10000);
  const exited = new Promise((resolve) => {
    child.on("error", (error) => resolve({ error }));
    child.on("exit", (code, signal) => resolve({ code, signal }));
  });
  let socket;
  try {
    const info = await new Promise((resolve, reject) => {
      child.stdout.on("data", (b) => {
        stdout += b.toString();
        if (stdout.length > 16384) {
          child.kill();
          reject(new Error("probe_output_limit"));
        } else if (stdout.includes("\n")) {
          try {
            resolve(JSON.parse(stdout.split("\n")[0]));
          } catch (error) {
            reject(error);
          }
        }
      });
      child.stderr.on("data", (b) => {
        stderr += b.toString();
        if (stderr.length > 8192) {
          child.kill();
          reject(new Error("probe_error_limit"));
        }
      });
      child.once("error", reject);
      child.once("exit", () => reject(new Error("probe_ended_before_ready")));
    });
    assert.equal(info.scope, "synthetic-loopback-only");
    assert.equal(info.inputEnabled, false);
    socket = await run(info);
    socket?.destroy();
    const end = await exited;
    assert.equal(end.error, undefined);
    assert.equal(end.code, 0);
    assert.equal(stderr, "");
    return stdout;
  } catch (error) {
    throw new Error(
      `native_tls_probe_failed: ${stderr}; ${stdout.split("\n").slice(1).filter(Boolean).join(";")}`,
      { cause: error },
    );
  } finally {
    socket?.destroy();
    clearTimeout(deadline);
    child.kill();
  }
}
function tlsOptions(info, pin = info.pin, version = "TLSv1.3") {
  const der = Buffer.from(info.certificateDER, "hex");
  assert.equal(createHash("sha256").update(der).digest("hex"), info.pin);
  const pem = `-----BEGIN CERTIFICATE-----\n${der
    .toString("base64")
    .match(/.{1,64}/g)
    .join("\n")}\n-----END CERTIFICATE-----\n`;
  return {
    host: "127.0.0.1",
    port: info.port,
    servername: serverName,
    ca: pem,
    minVersion: version,
    maxVersion: version,
    ALPNProtocols: [alpn],
    rejectUnauthorized: true,
    checkServerIdentity: (name, cert) =>
      checkServerIdentity(name, cert) ??
      (createHash("sha256").update(cert.raw).digest("hex") === pin
        ? undefined
        : new Error("host_pin_mismatch")),
  };
}
function establish(options) {
  return new Promise((resolve, reject) => {
    const socket = connect(options);
    socket.setTimeout(3000, () => socket.destroy(new Error("tls_timeout")));
    socket.once("secureConnect", () => resolve(socket));
    socket.once("error", reject);
  });
}
function frames(socket) {
  let buffer = Buffer.alloc(0),
    pending;
  const queue = [];
  let failed;
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length > 131072)
      return socket.destroy(new Error("frame_buffer_limit"));
    while (buffer.length >= 5) {
      const total = buffer.readUInt32BE();
      if (total < 2 || total > 65537)
        return socket.destroy(new Error("invalid_frame_length"));
      if (buffer.length < 4 + total) break;
      const frame = { kind: buffer[4], payload: buffer.subarray(5, 4 + total) };
      buffer = buffer.subarray(4 + total);
      if (pending) {
        const { resolve } = pending;
        pending = undefined;
        resolve(frame);
      } else {
        if (queue.length >= 16)
          return socket.destroy(new Error("frame_queue_limit"));
        queue.push(frame);
      }
    }
  });
  const fail = (error) => {
    failed = error;
    if (pending) {
      pending.reject(error);
      pending = undefined;
    }
  };
  socket.on("error", fail);
  socket.on("close", () => fail(new Error("tls_closed")));
  return {
    send(kind, payload) {
      const header = Buffer.alloc(5);
      header.writeUInt32BE(payload.length + 1);
      header[4] = kind;
      socket.write(Buffer.concat([header, payload]));
    },
    receive() {
      if (queue.length) return Promise.resolve(queue.shift());
      if (failed) return Promise.reject(failed);
      assert.equal(pending, undefined);
      return new Promise((resolve, reject) => {
        pending = { resolve, reject };
      });
    },
  };
}
await probe(async (info) => {
  const socket = await establish(tlsOptions(info));
  assert.equal(socket.authorized, true);
  assert.equal(socket.getProtocol(), "TLSv1.3");
  assert.equal(socket.alpnProtocol, alpn);
  assert.equal(socket.isSessionReused(), false);
  const peer = frames(socket);
  peer.send(1, Buffer.from("native-control-v1"));
  assert.equal((await peer.receive()).payload.toString(), "native-control-v1");
  const exchange = async (hex, ok, report) => {
    peer.send(2, Buffer.from(hex, "hex"));
    const frame = await peer.receive();
    assert.equal(frame.kind, 1);
    const result = JSON.parse(frame.payload);
    assert.equal(result.ok, ok);
    assert.equal(result.snapshot.inputEnabled, false);
    assert.equal(result.snapshot.reportHex, report);
    return result;
  };
  await exchange(
    fixture.invalidAuthenticated[0].packetHex,
    false,
    fixture.vectors[0].reportHex,
  );
  await exchange(
    fixture.vectors[0].packetHex,
    true,
    fixture.vectors[0].reportHex,
  );
  await exchange(
    fixture.vectors[1].packetHex,
    true,
    fixture.vectors[1].reportHex,
  );
  assert.equal(
    (
      await exchange(
        fixture.vectors[1].packetHex,
        false,
        fixture.vectors[1].reportHex,
      )
    ).error,
    "input_packet_rejected",
  );
  await exchange(
    fixture.maximumSequencePacketHex,
    true,
    fixture.vectors[0].reportHex,
  );
  return socket;
});
for (const mode of ["wrong-pin", "tls12"]) {
  const output = await probe(async (info) => {
    let accepted;
    try {
      accepted = await establish(
        tlsOptions(
          info,
          mode === "wrong-pin" ? "0".repeat(64) : info.pin,
          mode === "tls12" ? "TLSv1.2" : "TLSv1.3",
        ),
      );
    } catch {
      return undefined;
    } finally {
      accepted?.destroy();
    }
    throw new Error(`accepted_${mode}`);
  });
  assert.equal(
    JSON.parse(output.trim().split("\n").at(-1)).handshakeRejected,
    true,
  );
}
console.log(
  `Node ${process.version}; OpenSSL ${process.versions.openssl}; native TLS 1.3 control/input, semantic rejection, replay repair and pin/downgrade rejection passed`,
);
