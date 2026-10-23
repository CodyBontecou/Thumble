import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import type { ReadableStreamDefaultReader } from "node:stream/web";
import {
  readEndpoint,
  request,
  requestConfiguration,
  requestPairing,
  type Endpoint,
} from "@thumble/client/local";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { SqliteConfigurationRepository } from "@thumble/storage";

const ROOT = resolve(import.meta.dir, "..");
const RECEIVER =
  process.env.THUMBLE_EDITOR_RECEIVER ??
  join(ROOT, "native/receiver/target/debug/thumble-rewrite-receiver");
const PROFILE = "e1000000-0000-0000-0000-000000000001";
const row = (value: unknown): Record<string, any> => {
  assert(value !== null && typeof value === "object", "cross_layer_object");
  return value as Record<string, any>;
};
const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until<T>(
  action: () => Promise<T | undefined>,
  budget = 5000,
): Promise<T> {
  const end = performance.now() + budget;
  for (;;) {
    const result = await action();
    if (result !== undefined) return result;
    assert(performance.now() < end, "cross_layer_wait");
    await pause(5);
  }
}
class PhoneCall {
  readonly child: Bun.Subprocess<"pipe", "pipe", "ignore">;
  private reader: ReadableStreamDefaultReader<Uint8Array>;
  private buffered = "";
  constructor(config: unknown) {
    this.child = Bun.spawn(
      [
        process.env.THUMBLE_EDITOR_PYTHON ?? "python3",
        join(ROOT, "tooling/editor-cross-layer-client.py"),
      ],
      { stdin: "pipe", stdout: "pipe", stderr: "ignore" },
    );
    this.reader = (this.child.stdout as ReadableStream<Uint8Array>).getReader();
    this.child.stdin!.write(JSON.stringify(config) + "\n");
    this.child.stdin!.end();
  }
  async next(): Promise<Record<string, any>> {
    for (;;) {
      const end = this.buffered.indexOf("\n");
      if (end >= 0) {
        const line = this.buffered.slice(0, end);
        this.buffered = this.buffered.slice(end + 1);
        return row(JSON.parse(line));
      }
      const part = await this.reader.read();
      assert(!part.done, "cross_layer_client_eof");
      this.buffered += new TextDecoder().decode(part.value);
      assert(this.buffered.length < 32768, "cross_layer_client_bound");
    }
  }
  async finish() {
    const value = await this.next();
    assert(
      !value.failed,
      typeof value.failed === "string"
        ? value.failed
        : "cross_layer_client_error",
    );
    await this.child.exited;
    return value;
  }
}
(process.env.THUMBLE_REWRITE_EDITOR_CROSS_LAYER === "1" &&
  process.platform !== "win32"
  ? test
  : test.skip)(
  "real service role12 persists edits and policy ACK follows actual pending owner completion",
  async () => {
    assert(process.platform !== "win32", "cross_layer_unix_gate");
    const parent = join(
      ROOT,
      "build/cross-layer-state",
      `${process.pid}-${Date.now()}`,
    );
    mkdirSync(parent, { recursive: true, mode: 0o700 });
    chmodSync(parent, 0o700);
    const directory = join(realpathSync(parent), "runtime"),
      identity = join(parent, "identity"),
      cli = join(ROOT, "apps/cli/src/main.ts");
    let service: Bun.Subprocess<"ignore", "ignore", "ignore"> | undefined,
      local: Endpoint | undefined,
      stopped: number | undefined;
    const phases: string[] = [];
    try {
      const seed = new SqliteConfigurationRepository(directory, RECEIVER);
      seed.commit({
        operationId: "cross-layer-seed",
        payloadHash: "a".repeat(64),
        expectedRevision: "0",
        source: starterConfiguration(PROFILE, "Synthetic editor", "100"),
        affectedEntities: [PROFILE],
      });
      const initial = seed.current()!;
      seed.close();
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
        { stdio: "ignore", timeout: 5000 },
      );
      service = Bun.spawn(
        [
          process.execPath,
          cli,
          "service",
          "run",
          "--runtime-dir",
          directory,
          "--receiver",
          RECEIVER,
          "--identity-dir",
          identity,
          "--output",
          "recording",
        ],
        { stdout: "ignore", stderr: "ignore" },
      );
      local = await until(async () => {
        assert(service!.exitCode === null, "cross_layer_service_exit");
        try {
          return readEndpoint(directory, RECEIVER);
        } catch {
          return undefined;
        }
      });
      const opened = await requestPairing(local, {
        command: "pairing-listen",
        bindAddress: "127.0.0.1:0",
        advertiseHost: "127.0.0.1",
      });
      const transport = row(opened.transport),
        endpoint = {
          host: "127.0.0.1",
          port: transport.port,
          pin: transport.certificatePin,
          authority: local.instanceId,
        };
      const enroll = async (offer: unknown) => {
        const call = new PhoneCall({ mode: "enroll", endpoint, offer });
        const result = await call.finish();
        assert(result.credential, "cross_layer_enrollment");
        return result.credential;
      };
      let credential = await enroll(opened.offer);
      const start = (
        input: Record<string, unknown>,
        extra?: Record<string, unknown>,
      ) =>
        new PhoneCall({
          mode: "rpc",
          endpoint,
          credential,
          request: input,
          extra,
        });
      const rpc = async (
        input: Record<string, unknown>,
        extra?: Record<string, unknown>,
      ) => {
        const call = start(input, extra);
        assert((await call.next()).sent, "cross_layer_sent");
        return call.finish();
      };
      const profile = await rpc({
        command: "editor-profile",
        expectedRevision: "1",
        expectedSourceHash: initial.contentHash,
        profileId: PROFILE,
        offset: 0,
      });
      assert(profile.reply?.kind === "editor-profile", "cross_layer_profile");
      const control = profile.reply.controls[0].id;
      phases.push("pinned-profile");
      const ownedConfigurationChild = () => {
        const listing = execFileSync("ps", ["-axo", "pid=,ppid=,command="], {
          encoding: "utf8",
          maxBuffer: 1024 * 1024,
        });
        const children = listing
          .split("\n")
          .map((line) => line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/))
          .filter(
            (match) =>
              match &&
              Number(match[2]) === service!.pid &&
              match[3]!.includes("__configuration") &&
              match[3]!.includes(directory),
          );
        assert(children.length === 1, "cross_layer_exact_child");
        return Number(children[0]![1]);
      };
      const intent = {
        command: "configuration-set-control-label",
        operationId: "cross-layer-label",
        expectedRevision: "1",
        profileId: PROFILE,
        controlId: control,
        label: "Persisted editor label",
      };
      // Hold a real preexisting CLI read, then reserve the phone write behind it.
      stopped = ownedConfigurationChild();
      process.kill(stopped, "SIGSTOP");
      const ordinary = requestConfiguration(local, {
        command: "configuration-list",
        expectedRevision: null,
        offset: 0,
      });
      await pause(10);
      const firstSave = start(intent);
      assert((await firstSave.next()).sent, "cross_layer_busy_save_sent");
      await pause(10);
      process.kill(stopped, "SIGCONT");
      stopped = undefined;
      assert(
        row(await ordinary).revision === "1",
        "cross_layer_preexisting_cli_read",
      );
      const committed = await firstSave.finish();
      assert(committed.reply?.kind === "committed", "cross_layer_committed");
      phases.push("write-reserved-behind-actual-cli-read");
      const receipt = committed.reply.receipt;
      assert(receipt.resultingRevision === "2", "cross_layer_revision2");
      phases.push("actual-child-commit");
      const status = await rpc({ command: "editor-label-status", intent });
      assert(
        status.reply?.kind === "editor-label-receipt" &&
          JSON.stringify(status.reply.receipt) === JSON.stringify(receipt),
        "cross_layer_exact_receipt",
      );
      const duplicate = await rpc(intent);
      assert(
        duplicate.reply?.kind === "committed" &&
          duplicate.reply.replayed === true &&
          duplicate.reply.receipt.resultingRevision === "2",
        "cross_layer_duplicate",
      );
      const page2 = await rpc({
        command: "editor-profile",
        expectedRevision: "2",
        expectedSourceHash: receipt.contentHash,
        profileId: PROFILE,
        offset: 0,
      });
      assert(
        page2.reply?.controls[0].labelOverride === intent.label,
        "cross_layer_persisted_label",
      );
      assert(
        row(
          await requestConfiguration(local, {
            command: "configuration-list",
            expectedRevision: null,
            offset: 0,
          }),
        ).revision === "2",
        "cross_layer_no_second_revision",
      );
      phases.push("receipt-and-idempotent-retry");
      const reused = await rpc({
        command: "editor-label-status",
        intent: { ...intent, label: "Wrong original intent" },
      });
      assert(
        reused.reply?.error === "editor_operation_reused",
        "cross_layer_original_intent",
      );
      assert(
        (
          await rpc(
            { command: "editor-label-status", intent },
            { authorityInstanceId: "99999999-9999-9999-9999-999999999999" },
          )
        ).closed,
        "cross_layer_authority",
      );
      assert(
        (
          await rpc(
            { command: "editor-label-status", intent },
            { ownerLifetimeId: "99999999-9999-9999-9999-999999999999" },
          )
        ).closed,
        "cross_layer_phone_context",
      );
      phases.push("strict-rejections");
      stopped = ownedConfigurationChild();
      process.kill(stopped, "SIGSTOP");
      const pendingIntent = {
        ...intent,
        operationId: "cross-layer-pending",
        expectedRevision: "2",
        label: "Committed after policy wait",
      };
      const pending = start(pendingIntent);
      assert((await pending.next()).sent, "cross_layer_pending_sent");
      await pause(10);
      await until(async () => {
        try {
          await requestConfiguration(local!, {
            command: "configuration-list",
            expectedRevision: null,
            offset: 0,
          });
          return undefined;
        } catch (e) {
          return e instanceof Error && e.message === "configuration_owner_busy"
            ? true
            : undefined;
        }
      }, 500);
      const admitted = await pending.finish();
      assert(
        admitted.reply?.kind === "editor-label-admitted",
        "cross_layer_slow_admitted",
      );
      // The actual owner is still paused: this read proves role12 stays healthy,
      // and its busy result cannot settle the retained write.
      const stillPending = await rpc({
        command: "editor-label-status",
        intent: pendingIntent,
      });
      assert(
        stillPending.reply?.error === "editor_busy",
        "cross_layer_slow_writer_still_healthy",
      );
      process.kill(stopped, 0);
      phases.push("slow-accepted-write-outlives-phone-response-budget");
      let acknowledged = 0;
      const revoked = Array.from({ length: 4 }, () =>
        requestPairing(local!, {
          command: "pairing-revoke",
          phoneId: "cross-layer-phone",
        }).then(async (result) => {
          acknowledged++;
          const observed = row(
            await requestConfiguration(local!, {
              command: "configuration-list",
              expectedRevision: null,
              offset: 0,
            }),
          );
          assert(
            observed.revision === "3",
            "cross_layer_each_ack_after_actual_commit",
          );
          return result;
        }),
      );
      await requestPairing(local, { command: "pairing-status" });
      assert(!acknowledged, "cross_layer_premature_ack");
      phases.push("stdin-progress-with-actual-child-pending");
      process.kill(stopped, "SIGCONT");
      stopped = undefined;
      await Promise.all(revoked);
      assert(acknowledged === 4, "cross_layer_four_policy_acks");
      phases.push("four-revoke-acks-after-actual-completion");
      assert(
        row(
          await requestConfiguration(local, {
            command: "configuration-list",
            expectedRevision: null,
            offset: 0,
          }),
        ).revision === "3",
        "cross_layer_policy_commit_revision",
      );
      const offer = await requestPairing(local, { command: "pairing-open" });
      credential = await enroll(offer.offer);
      const reconciled = await rpc({
        command: "editor-label-status",
        intent: pendingIntent,
      });
      assert(
        reconciled.reply?.kind === "editor-label-receipt" &&
          reconciled.reply.receipt.resultingRevision === "3",
        "cross_layer_pending_exact_receipt",
      );
      const page3 = await rpc({
        command: "editor-profile",
        expectedRevision: "3",
        expectedSourceHash: reconciled.reply.receipt.contentHash,
        profileId: PROFILE,
        offset: 0,
      });
      assert(
        page3.reply?.controls[0].labelOverride === pendingIntent.label,
        "cross_layer_policy_persisted",
      );
      const revisions = ["1", "2", "2", "3"];
      let latestRevision = "3";
      let latestHash = reconciled.reply.receipt.contentHash;
      let sdk: Record<string, unknown> | undefined;
      if (process.env.THUMBLE_EDITOR_SWIFT_COMMAND) {
        const command: unknown = JSON.parse(
          process.env.THUMBLE_EDITOR_SWIFT_COMMAND,
        );
        assert(
          Array.isArray(command) &&
            command.length > 0 &&
            command.every((v) => typeof v === "string"),
          "cross_layer_swift_command",
        );
        assert(
          Number.isSafeInteger(Number(credential.credentialEpoch)),
          "cross_layer_fixture_epoch",
        );
        const fixture = join(parent, "sdk-fixture-private.json");
        const summary = join(parent, "sdk-summary.json");
        writeFileSync(
          fixture,
          JSON.stringify({
            version: 1,
            host: endpoint.host,
            port: endpoint.port,
            certificatePin: endpoint.pin,
            authorityInstanceId: endpoint.authority,
            phoneId: credential.phoneId,
            credentialEpoch: Number(credential.credentialEpoch),
            credential: credential.credential,
            expiresAt: credential.expiresAt,
            profileId: PROFILE,
            revision: "3",
            sourceHash: reconciled.reply.receipt.contentHash,
            controlId: control,
          }),
          { mode: 0o600 },
        );
        let helper: Bun.Subprocess<"ignore", "ignore", "ignore"> | undefined;
        try {
          helper = Bun.spawn(command as string[], {
            stdin: "ignore",
            stdout: "ignore",
            stderr: "ignore",
            env: {
              ...process.env,
              THUMBLE_EDITOR_SDK_FIXTURE: fixture,
              THUMBLE_EDITOR_SDK_SUMMARY: summary,
            },
          });
          let timer: ReturnType<typeof setTimeout> | undefined;
          const expired = new Promise<number>((resolve) => {
            timer = setTimeout(() => resolve(-1), 150000);
          });
          const exit = await Promise.race([helper.exited, expired]).finally(
            () => {
              if (timer) clearTimeout(timer);
            },
          );
          assert(exit === 0, "cross_layer_swift_helper_failed");
          sdk = row(JSON.parse(readFileSync(summary, "utf8")));
          const expected = {
            version: 1,
            kind: "swift-editor-sdk",
            committed: true,
            queueEmpty: true,
            baseRevision: "3",
            resultingRevision: "4",
          };
          assert(
            Object.keys(sdk).length === Object.keys(expected).length &&
              Object.entries(expected).every(
                ([key, value]) => sdk![key] === value,
              ),
            "cross_layer_swift_summary",
          );
        } finally {
          if (helper && helper.exitCode === null) {
            helper.kill();
            await helper.exited;
          }
          rmSync(fixture, { force: true });
        }
        const swiftIntent = {
          ...intent,
          operationId: "swift-cross-layer-label",
          expectedRevision: "3",
          label: "NativeSDK",
        };
        const swiftReceipt = await rpc({
          command: "editor-label-status",
          intent: swiftIntent,
        });
        assert(
          swiftReceipt.reply?.kind === "editor-label-receipt" &&
            swiftReceipt.reply.receipt.resultingRevision === "4",
          "cross_layer_swift_exact_receipt",
        );
        const swiftPage = await rpc({
          command: "editor-profile",
          expectedRevision: "4",
          expectedSourceHash: swiftReceipt.reply.receipt.contentHash,
          profileId: PROFILE,
          offset: 0,
        });
        assert(
          swiftPage.reply?.controls[0].labelOverride === "NativeSDK",
          "cross_layer_swift_persisted_label",
        );
        phases.push("swift-real-sdk-profile-commit-exact-receipt");
        latestRevision = "4";
        latestHash = swiftReceipt.reply.receipt.contentHash;
        revisions.push(latestRevision);
      }
      let android: Record<string, unknown> | undefined;
      if (process.env.THUMBLE_EDITOR_ANDROID_COMMAND) {
        const command: unknown = JSON.parse(
          process.env.THUMBLE_EDITOR_ANDROID_COMMAND,
        );
        assert(
          Array.isArray(command) &&
            command.length > 0 &&
            command.every((v) => typeof v === "string"),
          "cross_layer_android_command",
        );
        assert(
          Number.isSafeInteger(Number(credential.credentialEpoch)),
          "cross_layer_android_epoch",
        );
        const fixture = join(parent, "android-fixture-private.json");
        const summary = join(parent, "android-summary.json");
        const nextRevision = (BigInt(latestRevision) + 1n).toString();
        writeFileSync(
          fixture,
          JSON.stringify({
            version: 1,
            host: endpoint.host,
            port: endpoint.port,
            certificatePin: endpoint.pin,
            authorityInstanceId: endpoint.authority,
            phoneId: credential.phoneId,
            credentialEpoch: Number(credential.credentialEpoch),
            credential: credential.credential,
            expiresAt: credential.expiresAt,
            profileId: PROFILE,
            revision: latestRevision,
            sourceHash: latestHash,
            controlId: control,
          }),
          { mode: 0o600 },
        );
        let helper: Bun.Subprocess<"ignore", "ignore", "ignore"> | undefined;
        try {
          helper = Bun.spawn(command as string[], {
            stdin: "ignore",
            stdout: "ignore",
            stderr: "ignore",
            env: {
              ...process.env,
              THUMBLE_EDITOR_ANDROID_FIXTURE: fixture,
              THUMBLE_EDITOR_ANDROID_SUMMARY: summary,
            },
          });
          let timer: ReturnType<typeof setTimeout> | undefined;
          const expired = new Promise<number>((resolve) => {
            timer = setTimeout(() => resolve(-1), 240000);
          });
          const exit = await Promise.race([helper.exited, expired]).finally(
            () => {
              if (timer) clearTimeout(timer);
            },
          );
          assert(exit === 0, "cross_layer_android_helper_failed");
          android = row(JSON.parse(readFileSync(summary, "utf8")));
          const expected = {
            version: 1,
            kind: "kotlin-editor-sdk",
            committed: true,
            queueEmpty: true,
            baseRevision: latestRevision,
            resultingRevision: nextRevision,
          };
          assert(
            Object.keys(android).length === Object.keys(expected).length &&
              Object.entries(expected).every(
                ([key, value]) => android![key] === value,
              ),
            "cross_layer_android_summary",
          );
        } finally {
          if (helper && helper.exitCode === null) {
            helper.kill();
            await helper.exited;
          }
          rmSync(fixture, { force: true });
        }
        const androidIntent = {
          ...intent,
          operationId: "kotlin-cross-layer-label",
          expectedRevision: latestRevision,
          label: "AndroidSDK",
        };
        const androidReceipt = await rpc({
          command: "editor-label-status",
          intent: androidIntent,
        });
        assert(
          androidReceipt.reply?.kind === "editor-label-receipt" &&
            androidReceipt.reply.receipt.resultingRevision === nextRevision,
          "cross_layer_android_exact_receipt",
        );
        const androidPage = await rpc({
          command: "editor-profile",
          expectedRevision: nextRevision,
          expectedSourceHash: androidReceipt.reply.receipt.contentHash,
          profileId: PROFILE,
          offset: 0,
        });
        assert(
          androidPage.reply?.controls[0].labelOverride === "AndroidSDK",
          "cross_layer_android_persisted_label",
        );
        phases.push("kotlin-real-sdk-profile-commit-exact-receipt");
        revisions.push(nextRevision);
      }
      const evidence = {
        version: 1,
        scope: "synthetic-loopback-recording-only",
        phases,
        revisions,
        ...(sdk ? { sdk } : {}),
        ...(android ? { android } : {}),
        inputEnabled: false,
        physicalOutput: false,
      };
      const report = process.env.THUMBLE_EDITOR_EVIDENCE;
      if (report)
        writeFileSync(report, JSON.stringify(evidence) + "\n", { mode: 0o600 });
    } finally {
      if (stopped) process.kill(stopped, "SIGCONT");
      if (local)
        try {
          await request(local, { command: "stop" });
        } catch {}
      if (service) {
        await Promise.race([service.exited, pause(4000)]);
        if (service.exitCode === null) service.kill();
        await service.exited;
      }
      rmSync(parent, { recursive: true, force: true });
    }
  },
  process.env.THUMBLE_EDITOR_ANDROID_COMMAND
    ? 300000
    : process.env.THUMBLE_EDITOR_SWIFT_COMMAND
      ? 180000
      : 20000,
);
