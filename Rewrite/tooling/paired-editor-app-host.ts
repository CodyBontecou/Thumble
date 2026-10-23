#!/usr/bin/env bun
/** Opt-in actual recording authority for target-UID Android editor UI QA. */
import assert from "node:assert/strict";
import { Database } from "bun:sqlite";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import {
  readEndpoint,
  request,
  requestPairing,
  requestConfiguration,
  type Endpoint,
} from "@thumble/client/local";
import { LosslessJson } from "@thumble/contracts/json";
import { projectOwnedEditorProfilePage } from "@thumble/domain/owned-editor-profile";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import {
  SqliteConfigurationRepository,
  configurationSourceHash,
} from "@thumble/storage";
assert(
  process.env.THUMBLE_REWRITE_PAIRED_EDITOR_UI === "1",
  "paired_editor_opt_in_required",
);
assert(process.platform !== "win32", "paired_editor_unix_host");
const ROOT = resolve(import.meta.dir, "..");
const RECEIVER =
  process.env.THUMBLE_EDITOR_RECEIVER ??
  join(ROOT, "native/receiver/target/debug/thumble-rewrite-receiver");
const PROFILE = "e1000000-0000-0000-0000-000000000001";
const directory = join(
  ROOT,
  "build/paired-editor-private",
  `${process.pid}-${Date.now()}`,
);
mkdirSync(directory, { recursive: true, mode: 0o700 });
chmodSync(directory, 0o700);
const runtime = join(realpathSync(directory), "runtime"),
  identity = join(directory, "identity");
const evidence = join(ROOT, "build/paired-editor-evidence");
mkdirSync(evidence, { recursive: true });
const cli = join(ROOT, "apps/cli/src/main.ts");
let service: Bun.Subprocess | undefined, local: Endpoint | undefined;
let invitation: Record<string, unknown> | undefined,
  captured: Record<string, any> | undefined;
let enrolled = false,
  verified = false,
  cleaned = false;
let receiptEvidence: any;
let observedRevision = "1",
  independentSQLite = false;
let stopping = false;
let initialSourceHash = "",
  fixturePin = "",
  actualServiceExitObserved = false;
let startupPhase = "seed";
const phases: string[] = [];
const row = (value: unknown): Record<string, any> => {
  assert(
    value && typeof value === "object" && !Array.isArray(value),
    "paired_object",
  );
  return value as Record<string, any>;
};
async function until<T>(action: () => Promise<T | undefined>): Promise<T> {
  const end = performance.now() + 10000;
  for (;;) {
    const value = await action();
    if (value !== undefined) return value;
    assert(performance.now() < end, "paired_host_ready");
    await Bun.sleep(10);
  }
}
function state() {
  const db = new Database(join(runtime, "configuration-v1.sqlite3"), {
    readonly: true,
    strict: true,
  });
  try {
    const current = row(
      db
        .query(
          "SELECT revision,source,content_hash FROM configuration_state WHERE singleton=1",
        )
        .get(),
    );
    const receipts = db
      .query(
        "SELECT operation_id,revision,receipt_json FROM operation_receipts ORDER BY revision",
      )
      .all()
      .map(row);
    return { current, receipts };
  } finally {
    db.close();
  }
}
function summary() {
  return {
    version: 1,
    kind: "paired-android-editor-ui",
    enrolled,
    captured: Boolean(captured),
    verified,
    cleaned,
    baseRevision: "1",
    revision: observedRevision,
    persistedLabel: independentSQLite,
    actualKeystore: enrolled,
    diskJournalAcrossProcessRestart: Boolean(captured),
    exactReceiptAndDuplicate: verified,
    independentSQLiteAfterActualExit: independentSQLite,
    phases,
    receipt: receiptEvidence,
  };
}
async function revision() {
  assert(local, "paired_service_endpoint");
  const value = row(
    await requestConfiguration(local, {
      command: "configuration-list",
      expectedRevision: null,
      offset: 0,
    }),
  );
  observedRevision = value.revision;
  return value.revision;
}
async function shutdown() {
  if (stopping) return;
  stopping = true;
  try {
    if (local && service?.exitCode === null)
      await request(local, { command: "stop" });
    if (service) {
      await service.exited;
      actualServiceExitObserved = true;
    }
    if (verified && captured) {
      const actual = state();
      const stored = actual.receipts.find(
        (receipt) => receipt.operation_id === captured!.operationId,
      );
      assert(
        actual.current.revision === "2" && stored?.revision === "2",
        "paired_independent_sqlite_commit",
      );
      const source = LosslessJson.parse(actual.current.source);
      assert(
        configurationSourceHash(source) === actual.current.content_hash,
        "paired_exact_source_hash",
      );
      let control: { id: string; labelOverride: string | null } | undefined;
      for (let offset = 0; offset < 128; ) {
        const page = projectOwnedEditorProfilePage(source, {
          command: "editor-profile",
          expectedRevision: actual.current.revision,
          expectedSourceHash: actual.current.content_hash,
          profileId: captured.profileId,
          offset,
        });
        control = page.controls.find((item) => item.id === captured!.controlId);
        if (control || page.nextOffset === null) break;
        offset = page.nextOffset;
      }
      assert(
        control &&
          control.id === captured.controlId &&
          control.labelOverride === captured.label,
        "paired_exact_control_label",
      );
      const receipt = row(JSON.parse(stored.receipt_json));
      assert(
        receipt.operationId === captured.operationId &&
          receipt.resultingRevision === "2" &&
          receipt.contentHash === receiptEvidence.contentHash &&
          actual.current.content_hash === receiptEvidence.contentHash,
        "paired_independent_sqlite_receipt",
      );
      assert(
        JSON.stringify(receipt.affectedEntities) ===
          JSON.stringify([captured.profileId, captured.controlId]),
        "paired_independent_sqlite_entities",
      );
      independentSQLite = true;
      observedRevision = actual.current.revision;
      phases.push("independent-sqlite-after-actual-service-exit");
    }
    writeFileSync(
      join(evidence, "paired-host-summary.json"),
      JSON.stringify({ ...summary(), actualServiceExitObserved }, null, 2) +
        "\n",
    );
  } finally {
    invitation = undefined;
    rmSync(directory, { recursive: true, force: true });
    server.stop(true);
  }
}
const server = Bun.serve({
  maxRequestBodySize: 4096,
  hostname: "127.0.0.1",
  port: 0,
  async fetch(req) {
    try {
      const path = new URL(req.url).pathname;
      if (req.method === "GET" && path === "/fixture") {
        assert(local && invitation && !enrolled, "paired_offer_unavailable");
        return json({ version: 1, invitation });
      }
      if (req.method === "GET" && path === "/state") return json(summary());
      if (req.method === "POST" && path === "/finish") {
        assert(
          enrolled && captured && verified && cleaned,
          "paired_gate_incomplete",
        );
        assert((await revision()) === "2", "paired_one_revision");
        setTimeout(
          () =>
            void shutdown().catch(() => {
              console.error("paired_host_cleanup_failed");
              process.exitCode = 1;
            }),
          50,
        );
        return json({ version: 1, ok: true });
      }
      assert(
        req.method === "POST" &&
          Number(req.headers.get("content-length")) <= 4096,
        "paired_request_bound",
      );
      const text = await req.text();
      assert(Buffer.byteLength(text) <= 4096, "paired_request_bound");
      const value = row(JSON.parse(text));
      if (path === "/enrolled") {
        assert(
          !enrolled &&
            value.version === 1 &&
            value.keystoreRoundTrip === true &&
            value.targetUid === true,
          "paired_enrollment",
        );
        enrolled = true;
        invitation = undefined;
        phases.push("target-uid-production-enrollment-keystore");
      } else if (path === "/captured") {
        assert(
          enrolled &&
            !captured &&
            value.label === "PairedAndroid" &&
            value.expectedRevision === "1" &&
            typeof value.controlId === "string" &&
            /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
              value.controlId,
            ) &&
            value.profileId === PROFILE &&
            value.sourceHash === initialSourceHash &&
            value.certificatePin === fixturePin &&
            value.authorityInstanceId === local?.instanceId,
          "paired_original_intent",
        );
        assert(
          typeof value.operationId === "string" &&
            /^[A-Za-z0-9_-]{1,128}$/.test(value.operationId),
          "paired_operation",
        );
        assert((await revision()) === "1", "paired_queue_did_not_commit");
        captured = value;
        phases.push("actual-ui-queue-durable-across-process-restart");
      } else if (path === "/verified") {
        assert(
          captured &&
            !verified &&
            value.operationId === captured.operationId &&
            value.revision === "2" &&
            value.exactStatus === true &&
            value.duplicateCommitted === true,
          "paired_rpc_exact_receipt",
        );
        assert((await revision()) === "2", "paired_service_commit_revision");
        receiptEvidence = {
          operationId: captured.operationId,
          resultingRevision: value.revision,
          contentHash: value.hash,
          affectedEntities: [captured.profileId, captured.controlId],
        };
        verified = true;
        phases.push("actual-ui-commit-production-rpc-exact-status-duplicate");
      } else if (path === "/cleaned") {
        assert(
          enrolled && value.version === 1 && value.credentialForgotten === true,
          "paired_credential_cleanup",
        );
        cleaned = true;
        phases.push("target-uid-credential-cleanup");
      } else throw Error("paired_route");
      writeFileSync(
        join(evidence, "paired-host-progress.json"),
        JSON.stringify(summary(), null, 2) + "\n",
      );
      return json({ version: 1, ok: true });
    } catch {
      return json({ version: 1, error: "paired_witness_rejected" }, 400);
    }
  },
});
function json(value: unknown, status = 200) {
  const text = JSON.stringify(value);
  return new Response(text, {
    status,
    headers: {
      "content-type": "application/json",
      "content-length": String(Buffer.byteLength(text)),
      connection: "close",
    },
  });
}
try {
  const seed = new SqliteConfigurationRepository(runtime, RECEIVER);
  try {
    seed.commit({
      operationId: "paired-ui-seed",
      payloadHash: "a".repeat(64),
      expectedRevision: "0",
      source: starterConfiguration(PROFILE, "Paired editor witness", "100"),
      affectedEntities: [PROFILE],
    });
    initialSourceHash = seed.current()!.contentHash;
  } finally {
    seed.close();
  }
  startupPhase = "identity";
  execFileSync(
    process.execPath,
    [
      cli,
      "identity",
      "initialize",
      "--identity-dir",
      identity,
      "--receiver",
      RECEIVER,
      "--json",
    ],
    { stdio: ["ignore", "pipe", "pipe"], timeout: 10000 },
  );
  startupPhase = "service";
  service = Bun.spawn(
    [
      process.execPath,
      cli,
      "service",
      "run",
      "--runtime-dir",
      runtime,
      "--receiver",
      RECEIVER,
      "--identity-dir",
      identity,
      "--output",
      "recording",
    ],
    { stdin: "ignore", stdout: "ignore", stderr: "ignore" },
  );
  local = await until(async () => {
    assert(service!.exitCode === null, "paired_service_exit");
    try {
      return readEndpoint(runtime, RECEIVER);
    } catch {
      return undefined;
    }
  });
  startupPhase = "listen";
  const opened = row(
    await requestPairing(local, {
      command: "pairing-listen",
      bindAddress: "127.0.0.1:0",
      advertiseHost: "127.0.0.1",
    }),
  );
  const transport = row(opened.transport),
    offer = row(opened.offer);
  fixturePin = transport.certificatePin;
  invitation = {
    host: "127.0.0.1",
    port: transport.port,
    certificatePin: transport.certificatePin,
    authorityInstanceId: local.instanceId,
    windowId: offer.windowId,
    secret: offer.secret,
    expiresAt: offer.expiresAt,
  };
  phases.push("actual-bun-recording-service-child-sqlite-ready");
  const publicFixture = {
    version: 1,
    kind: "paired-editor-host-ready",
    fixturePort: server.port,
    tlsPort: transport.port,
    profileId: PROFILE,
  };
  writeFileSync(
    join(evidence, "endpoint.json"),
    JSON.stringify(publicFixture) + "\n",
    { mode: 0o600 },
  );
  console.log(JSON.stringify(publicFixture));
} catch (error) {
  let cliCode: string | undefined;
  try {
    const reply = JSON.parse(String((error as any).stdout));
    if (reply.ok === false && /^[a-z_]{1,80}$/.test(reply.error))
      cliCode = reply.error;
  } catch {}
  const code =
    cliCode ??
    (error instanceof Error && /^[a-z_]{1,80}$/.test(error.message)
      ? error.message
      : "other");
  console.error(`paired_host_start_failed phase=${startupPhase} code=${code}`);
  process.exitCode = 1;
  await shutdown();
}
process.on("SIGTERM", () => void shutdown());
process.on("SIGINT", () => void shutdown());
