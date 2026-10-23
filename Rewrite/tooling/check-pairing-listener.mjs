// Independent test-only peer. Never installed with the CLI or used as a phone input sender.
import assert from "node:assert/strict";
import { createHash, X509Certificate } from "node:crypto";
import { createInterface } from "node:readline";
import { connect } from "node:tls";
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
const commands = input[Symbol.asyncIterator]();
const first = await commands.next();
assert(!first.done);
const {
  invitation,
  transport,
  pause = false,
  catalog = null,
} = JSON.parse(first.value);
const der = Buffer.from(transport.certificateDER, "hex");
assert.equal(
  createHash("sha256").update(der).digest("hex"),
  invitation.certificatePin,
);
const certificate = new X509Certificate(der);
const options = {
  host: invitation.host,
  port: invitation.port,
  servername: "thumble-rewrite.local",
  ca: certificate.toString(),
  rejectUnauthorized: true,
  minVersion: "TLSv1.3",
  maxVersion: "TLSv1.3",
  ALPNProtocols: ["thumble-rewrite-control/1"],
};
let socket = connect(options);
const deadline = setTimeout(
  () => socket.destroy(new Error("pairing_oracle_deadline")),
  12000,
);
try {
  async function verifyPinnedSocket() {
    await new Promise((resolve, reject) => {
      socket.once("secureConnect", resolve);
      socket.once("error", reject);
    });
    assert.equal(socket.getProtocol(), "TLSv1.3");
    assert.equal(socket.alpnProtocol, "thumble-rewrite-control/1");
    assert.equal(
      createHash("sha256")
        .update(socket.getPeerCertificate().raw)
        .digest("hex"),
      invitation.certificatePin,
    );
  }
  await verifyPinnedSocket();
  let bytes = Buffer.alloc(0);
  let incoming = socket[Symbol.asyncIterator]();
  async function receive() {
    async function need(count) {
      while (bytes.length < count) {
        const next = await incoming.next();
        assert(!next.done);
        bytes = Buffer.concat([bytes, next.value]);
        assert(bytes.length <= 131072);
      }
    }
    await need(4);
    const length = bytes.readUInt32BE();
    assert(length >= 2 && length <= 65537);
    await need(4 + length);
    assert.equal(bytes[4], 1);
    const value = JSON.parse(bytes.subarray(5, 4 + length).toString("utf8"));
    bytes = bytes.subarray(4 + length);
    return value;
  }
  function send(value) {
    const json = Buffer.from(JSON.stringify(value));
    const frame = Buffer.alloc(5);
    frame.writeUInt32BE(json.length + 1);
    frame[4] = 1;
    socket.write(Buffer.concat([frame, json]));
  }
  send({
    version: 1,
    command: "hello",
    controlVersion: 2,
    inputVersion: 1,
    documentVersion: 1,
    capabilitiesVersion: 1,
  });
  const hello = await receive();
  assert.equal(hello.authorityInstanceId, invitation.authorityInstanceId);
  assert.equal(hello.inputEnabled, false);
  if (pause) {
    console.log(JSON.stringify({ phase: "hello", inputEnabled: false }));
    const next = await commands.next();
    assert(!next.done && next.value === "continue");
  }
  send({
    version: 1,
    command: "enroll",
    authorityInstanceId: invitation.authorityInstanceId,
    windowId: invitation.windowId,
    proof: invitation.secret,
    phoneId: "oracle-phone",
    label: "Synthetic native-listener peer",
  });
  if (pause) {
    let rejected = false;
    try {
      await receive();
    } catch {
      rejected = true;
    }
    assert(rejected);
    console.log(JSON.stringify({ proofRejected: true, inputEnabled: false }));
  } else {
    const reply = await receive();
    assert.equal(reply.version, 1);
    assert.equal(reply.command, "enrolled");
    assert.equal(reply.phoneId, "oracle-phone");
    assert(/^[1-9][0-9]*$/.test(reply.credentialEpoch));
    assert(
      typeof reply.credential === "string" &&
        /^[0-9a-f]{64}$/.test(reply.credential),
    );
    send({
      version: 1,
      command: "enrollment-stored",
      phoneId: reply.phoneId,
      credentialEpoch: reply.credentialEpoch,
    });
    const complete = await receive();
    assert.equal(complete.command, "enrollment-complete");
    assert.equal(complete.phoneId, reply.phoneId);
    assert.equal(complete.credentialEpoch, reply.credentialEpoch);
    assert.equal(complete.inputEnabled, false);
    socket.destroy();
    socket = connect(options);
    await verifyPinnedSocket();
    bytes = Buffer.alloc(0);
    incoming = socket[Symbol.asyncIterator]();
    send({
      version: 1,
      command: "hello",
      controlVersion: catalog ? 7 : 3,
      ...(catalog ? { role: "management" } : {}),
      inputVersion: 1,
      documentVersion: 1,
      capabilitiesVersion: 1,
    });
    const controlHello = await receive();
    assert.equal(controlHello.controlVersion, catalog ? 7 : 3);
    if (catalog) assert.equal(controlHello.role, "management");
    assert.equal(
      controlHello.authorityInstanceId,
      invitation.authorityInstanceId,
    );
    send({
      version: 1,
      command: "authenticate",
      authorityInstanceId: invitation.authorityInstanceId,
      phoneId: reply.phoneId,
      credentialEpoch: reply.credentialEpoch,
      credential: reply.credential,
    });
    const authorized = await receive();
    assert.equal(authorized.command, "authenticated");
    assert.equal(authorized.phoneId, reply.phoneId);
    assert.equal(authorized.credentialEpoch, reply.credentialEpoch);
    assert.equal(authorized.inputEnabled, false);
    assert.equal(authorized.inputSessionAvailable, false);
    assert(/^[0-9a-f]{32}$/.test(authorized.connectionId));
    assert(!JSON.stringify(authorized).includes(reply.credential));
    if (catalog) {
      assert.equal(authorized.role, "management");
      send({
        version: 1,
        command: "configuration-list",
        connectionId: authorized.connectionId,
        expectedRevision: catalog.expectedRevision,
        offset: catalog.offset,
      });
      const result = await receive();
      assert.equal(result.version, 1);
      assert.equal(result.command, "configuration-result");
      assert.equal(result.connectionId, authorized.connectionId);
      const { version, command, connectionId, ...metadata } = result;
      assert.deepEqual(metadata, catalog.expected);
      assert(!JSON.stringify(result).includes(reply.credential));
      console.log(
        JSON.stringify({
          authenticated: true,
          completed: true,
          inputEnabled: false,
          catalog: metadata,
        }),
      );
    } else {
      send({
        version: 1,
        command: "control-status",
        connectionId: authorized.connectionId,
      });
      assert.equal((await receive()).command, "control-status");
      send({
        version: 1,
        command: "disconnect",
        connectionId: authorized.connectionId,
      });
      assert.equal((await receive()).command, "disconnected");
      console.log(
        JSON.stringify({
          authenticated: true,
          completed: true,
          phoneId: complete.phoneId,
          credentialEpoch: complete.credentialEpoch,
          inputEnabled: false,
        }),
      );
    }
  }
} finally {
  clearTimeout(deadline);
  socket.destroy();
  input.close();
}
