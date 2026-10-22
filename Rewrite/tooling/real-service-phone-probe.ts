#!/usr/bin/env bun
import { ProbePhaseGate } from "./probe-phase-gate.ts";
/** Synthetic QA: real CLI service/native TLS/saved authority; recording output only. */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  writeFileSync,
  rmSync,
  openSync,
  readSync,
  closeSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  readEndpoint,
  requestSavedRuntime,
  request,
  requestConfiguration,
  requestPairing,
} from "@thumble/client/local";
import { parseStrictJson, type Snapshot } from "@thumble/contracts/receiver";
export const FIRST = "aaaaaaaa-0000-0000-0000-000000000001",
  SECOND = "bbbbbbbb-0000-0000-0000-000000000002";
const NEUTRAL = "0014000000000000000000000000000000000000",
  SOUTH = "0014001000000000000000000000000000000000",
  TRIGGER = "00140010ff000000000000000000000000000000",
  ANALOG = "0014001066663333000000003333000000000000";
const ROOT = resolve(import.meta.dir, "..");
function object(value: unknown): Record<string, unknown> {
  assert(
    value !== null && typeof value === "object" && !Array.isArray(value),
    "probe_object",
  );
  return value as Record<string, unknown>;
}
function records(path: string, offset: number) {
  const bytes = Buffer.alloc(65536),
    file = openSync(path, "r");
  let count: number;
  try {
    count = readSync(file, bytes, 0, bytes.length, offset);
  } finally {
    closeSync(file);
  }
  const last = bytes.subarray(0, count).lastIndexOf(10);
  if (last < 0) {
    assert(count < bytes.length, "probe_record_too_large");
    return { rows: [], offset };
  }
  const text = new TextDecoder("utf-8", { fatal: true }).decode(
    bytes.subarray(0, last),
  );
  return {
    rows: text
      .split("\n")
      .filter(Boolean)
      .map((line) => object(parseStrictJson(line))),
    offset: offset + last + 1,
  };
}
/** Fixed synthetic failure code only; never expose native report bytes or arbitrary reasons. */
export function neutralWaitFailure(
  phase: "fresh" | "packet_zero",
  snapshot:
    | Pick<Snapshot, "active" | "reportHex" | "lastReleaseReason">
    | undefined,
): string {
  assert(
    phase === "fresh" || phase === "packet_zero",
    "probe_diagnostic_phase",
  );
  const reasons = [
    "input_expired",
    "lease_expired",
    "native_input_released",
    "packet_source_barrier",
    "activation_barrier",
    "output_failed",
    "explicit_release",
    "shutdown",
  ];
  const reason =
    snapshot && reasons.includes(snapshot.lastReleaseReason)
      ? snapshot.lastReleaseReason
      : "other";
  return `probe_${phase}_timeout_${snapshot?.active === true ? "active" : "inactive"}_${snapshot?.reportHex === NEUTRAL ? "neutral" : "changed"}_${reason}`;
}

export class RealServicePhoneProbe {
  private readonly analogController =
    process.argv.includes("--saved-controller-analog") ||
    process.argv.includes("--saved-controller-analog-unsupported");
  private readonly savedController =
    this.analogController ||
    process.argv.includes("--saved-controller") ||
    process.argv.includes("--saved-controller-unsupported") ||
    process.argv.includes("--saved-controller-corner");
  private savedSeed(): Record<string, unknown> {
    const seed = object(
      parseStrictJson(
        readFileSync(
          resolve(
            ROOT,
            "packages/fixtures",
            this.analogController
              ? "saved-controller-analog-v1.json"
              : "saved-controller-v1.json",
          ),
          "utf8",
        ),
      ),
    );
    if (process.argv.includes("--saved-controller-analog-unsupported")) {
      assert(
        Array.isArray(seed.profiles) && seed.profiles.length === 2,
        "probe_seed_profiles",
      );
      const customization = object(object(seed.profiles[1]).customization);
      assert(
        Array.isArray(customization.elements) &&
          customization.elements.length === 5,
        "probe_seed_controls",
      );
      object(object(customization.elements[0]).layout).rotationDegrees = 45;
    }
    if (
      process.argv.includes("--saved-controller-unsupported") ||
      process.argv.includes("--saved-controller-corner")
    ) {
      assert(
        Array.isArray(seed.profiles) && seed.profiles.length === 2,
        "probe_seed_profiles",
      );
      const customization = object(object(seed.profiles[1]).customization);
      assert(
        Array.isArray(customization.elements) &&
          customization.elements.length === 1,
        "probe_seed_controls",
      );
      const layout = object(object(customization.elements[0]).layout);
      if (process.argv.includes("--saved-controller-unsupported"))
        layout.rotationDegrees = 45;
      if (process.argv.includes("--saved-controller-corner")) {
        layout.centerX = 1;
        layout.centerY = 0;
      }
    }
    return seed;
  }

  readonly parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-real-phone-")),
  );
  readonly directory = join(this.parent, "runtime");
  readonly receiver = resolve(
    ROOT,
    "native/receiver/target/debug/thumble-rewrite-receiver" +
      (process.platform === "win32" ? ".exe" : ""),
  );
  private service?: ReturnType<typeof Bun.spawn>;
  private endpoint?: ReturnType<typeof readEndpoint>;
  private activationOffset = 0;
  private watch:
    | {
        started: number;
        offset: number;
        sequence: bigint;
        samples: number;
        rotations: number;
        expected: string;
        kind: "renewal" | "catalog" | "analog";
      }
    | undefined;
  private closed = false;
  private readonly gate = new ProbePhaseGate();
  private timer?: ReturnType<typeof setInterval>;
  private readonly deadline = performance.now() + 180000;
  private diagnose(code: string) {
    if (process.env.THUMBLE_REAL_SERVICE_PROBE_DIAGNOSTICS !== "1") return;
    const candidate = process.env.THUMBLE_REAL_SERVICE_PROBE_TAG;
    const tag =
      candidate &&
      [
        "tls",
        "udp",
        "udp-blackhole",
        "renewal-udp",
        "renewal-tls-fallback",
      ].includes(candidate)
        ? candidate
        : "single";
    process.stderr.write(`real_service_probe ${tag} ${code}\n`);
  }
  private invoke(family: string, action: string, flags: string[] = []) {
    const output = execFileSync(
      process.execPath,
      [
        resolve(ROOT, "apps/cli/src/main.ts"),
        family,
        action,
        ...(family === "identity" || action === "validate-file"
          ? []
          : ["--runtime-dir", this.directory]),
        ...(action === "validate-file" ? [] : ["--receiver", this.receiver]),
        "--json",
        ...flags,
      ],
      { timeout: 5000, maxBuffer: 65536, stdio: ["ignore", "pipe", "pipe"] },
    );
    const reply = object(parseStrictJson(output.toString("utf8")));
    assert(reply.ok === true, "probe_cli_rejected");
    return object(reply.result);
  }
  private get local() {
    assert(this.endpoint, "probe_not_started");
    return this.endpoint;
  }
  async start() {
    assert(!this.service && !this.closed, "probe_already_started");
    const identity = join(this.parent, "identity");
    this.invoke("identity", "initialize", ["--identity-dir", identity]);
    this.service = Bun.spawn(
      [
        process.execPath,
        resolve(ROOT, "apps/cli/src/main.ts"),
        "service",
        "run",
        "--runtime-dir",
        this.directory,
        "--receiver",
        this.receiver,
        "--identity-dir",
        identity,
      ],
      { stdout: "ignore", stderr: "ignore" },
    );
    void this.service.exited.then((code) =>
      this.diagnose(code === 0 ? "service_exit_zero" : "service_exit_nonzero"),
    );
    await this.until(async () => {
      assert(this.service?.exitCode === null, "probe_service_start_failed");
      try {
        this.endpoint = readEndpoint(this.directory, this.receiver);
        return true;
      } catch {
        return false;
      }
    }, 5000);
    const source = join(this.parent, "synthetic-profiles.json");
    writeFileSync(
      source,
      JSON.stringify(
        this.savedController
          ? this.savedSeed()
          : {
              schema: "com.codybontecou.pocketpad.keypad-configuration",
              version: 5,
              profiles: [
                {
                  id: FIRST,
                  name: "First",
                  updatedAt: 0,
                  profileFormatVersion: 5,
                  customization: {
                    deviceCanvas: { frameID: "iphone-17-pro-landscape" },
                    elements: [],
                  },
                },
                {
                  id: SECOND,
                  name: "Second",
                  updatedAt: 0,
                  profileFormatVersion: 5,
                  customization: {
                    deviceCanvas: { frameID: "iphone-17-pro-landscape" },
                    elements: [],
                  },
                },
              ],
              activeProfileID: SECOND,
              defaultProfileID: null,
            },
      ),
      { mode: 0o600 },
    );
    const inspection = this.invoke("configuration", "validate-file", [
      "--file",
      source,
    ]);
    assert(typeof inspection.contentHash === "string", "probe_hash");
    const flags = [
      "--operation-id",
      "real-phone-seed",
      "--expected-revision",
      "0",
      "--expected-source-hash",
      inspection.contentHash,
    ];
    this.invoke("configuration", "import-file", [...flags, "--file", source]);
    await this.until(async () => {
      const result = this.invoke("configuration", "import-status", flags);
      assert(
        result.kind === "import-pending" || result.kind === "import-committed",
        "probe_import_failed",
      );
      return result.kind === "import-committed";
    }, 5000);
    const catalog = object(
      await requestConfiguration(this.local, {
        command: "configuration-list",
        expectedRevision: null,
        offset: 0,
      }),
    );
    assert(
      catalog.kind === "catalog" &&
        Array.isArray(catalog.profiles) &&
        catalog.profiles.length === 2 &&
        catalog.activeProfileId === SECOND,
      "probe_saved_catalog",
    );
    const opened = await requestPairing(this.local, {
      command: "pairing-listen",
      bindAddress: "127.0.0.1:0",
      advertiseHost: "127.0.0.1",
    });
    assert(
      opened.offer &&
        opened.transport?.listening &&
        opened.transport.inputEnabled === false,
      "probe_listener",
    );
    this.timer = setInterval(() => {
      this.gate.observe(() => this.observe());
    }, 100);
    return {
      scope: "synthetic-loopback-recording-only",
      backend: "real-bun-service",
      profileCount: 2,
      port: opened.transport.port,
      pin: opened.transport.certificatePin,
      authorityInstanceId: opened.authorityInstanceId,
      windowId: opened.offer.windowId,
      secret: opened.offer.secret,
      expiresAt: opened.offer.expiresAt,
    };
  }
  private async snapshot(): Promise<Snapshot> {
    const value = (await request(this.local, { command: "status" })).receiver
      .snapshot;
    assert(
      value.backend === "recording" && value.inputEnabled === false,
      "probe_output_enabled",
    );
    return value;
  }
  private async until(predicate: () => Promise<boolean>, milliseconds = 1000) {
    const deadline = performance.now() + milliseconds;
    while (!(await predicate())) {
      assert(performance.now() < deadline, "probe_condition_timeout");
      await Bun.sleep(5);
    }
  }
  private async observe() {
    assert(performance.now() < this.deadline, "probe_deadline");
    if (!this.watch) return;
    const watch = this.watch,
      read = records(this.local.recordingLog, watch.offset);
    for (const row of read.rows) {
      assert(
        row.reason === "sample" && row.reportHex === watch.expected,
        "probe_continuous_hold_interrupted",
      );
      watch.samples++;
    }
    watch.offset = read.offset;
    const current = await this.snapshot();
    assert(
      current.active &&
        current.reportHex === watch.expected &&
        current.sequence !== null,
      "probe_continuous_hold_inactive",
    );
    const sequence = BigInt(current.sequence);
    if (sequence < watch.sequence) watch.rotations++;
    watch.sequence = sequence;
  }
  async command(byte: string): Promise<Record<string, unknown>> {
    return this.gate.command(async () => {
      if (/^[abvczhnfqjeko]$/.test(byte)) this.diagnose(`phase_${byte}`);
      const result = await this.handleCommand(byte);
      if (/^[abvczhnfqjeko]$/.test(byte)) this.diagnose(`done_${byte}`);
      return result;
    });
  }
  private async handleCommand(byte: string): Promise<Record<string, unknown>> {
    assert(
      !this.closed && performance.now() < this.deadline,
      "probe_unavailable",
    );
    if (byte === "a") {
      const current = await this.snapshot();
      let snapshot: Snapshot;
      if (this.savedController) {
        const catalog = object(
          await requestConfiguration(this.local, {
            command: "configuration-list",
            expectedRevision: null,
            offset: 0,
          }),
        );
        assert(
          typeof catalog.revision === "string" &&
            typeof catalog.contentHash === "string" &&
            catalog.activeProfileId === SECOND,
          "probe_saved_pin",
        );
        const result = await requestSavedRuntime(this.local, {
          command: "activate-saved",
          expectedReceiverRevision: current.revision,
          expectedConfigurationRevision: catalog.revision,
          expectedSourceHash: catalog.contentHash,
          profileId: SECOND,
        });
        assert(
          result.savedBinding?.sourceHash === catalog.contentHash &&
            result.savedBinding.profileId === SECOND,
          "probe_saved_activation",
        );
        snapshot = result.snapshot;
      } else {
        const result = await request(this.local, {
          command: "activate",
          expectedRevision: current.revision,
          profileId: SECOND,
        });
        snapshot = result.receiver.snapshot;
      }
      this.activationOffset = statSync(this.local.recordingLog).size;
      return {
        active: true,
        generation: snapshot.generation,
        revision: snapshot.revision,
        inputEnabled: false,
      };
    }
    if (byte === "e") {
      assert(this.savedController, "probe_saved_mode_required");
      const catalog = object(
        await requestConfiguration(this.local, {
          command: "configuration-list",
          expectedRevision: null,
          offset: 0,
        }),
      );
      assert(typeof catalog.revision === "string", "probe_saved_revision");
      const mutation = object(
        await requestConfiguration(this.local, {
          command: "configuration-rename-profile",
          operationId: "synthetic-saved-map-storage-edit",
          expectedRevision: catalog.revision,
          profileId: SECOND,
          name: "Edited storage only",
        }),
      );
      const receipt = object(mutation.receipt);
      const bound = await requestSavedRuntime(this.local, {
        command: "saved-binding-status",
      });
      assert(
        bound.savedBinding && bound.snapshot.active,
        "probe_saved_binding_lost",
      );
      return {
        storageEdited: true,
        configurationRevision: receipt.resultingRevision,
        savedConfigurationRevision: bound.savedBinding.configurationRevision,
        generation: bound.snapshot.generation,
        revision: bound.snapshot.revision,
        inputEnabled: false,
      };
    }
    if (byte === "b" || byte === "q" || byte === "k") {
      assert(
        byte !== "k" || this.analogController,
        "probe_analog_mode_required",
      );
      const expected = byte === "b" ? TRIGGER : byte === "k" ? ANALOG : SOUTH;
      assert(!this.watch, "probe_watch_exists");
      await this.until(async () => {
        const s = await this.snapshot();
        return s.active && s.reportHex === expected;
      });
      const current = await this.snapshot();
      let offset = this.activationOffset;
      const limit = statSync(this.local.recordingLog).size;
      for (let count = 0; count < 64; count++) {
        const read = records(this.local.recordingLog, offset);
        if (read.offset === offset || read.offset >= limit) {
          offset = read.offset;
          break;
        }
        offset = read.offset;
        assert(count < 63, "probe_record_backlog");
      }
      this.watch = {
        started: performance.now(),
        offset,
        sequence: BigInt(current.sequence!),
        samples: 0,
        rotations: 0,
        expected,
        kind: byte === "b" ? "renewal" : byte === "k" ? "analog" : "catalog",
      };
      return {
        watching: true,
        inputTtlMs: 350,
        minimumMs: byte === "b" ? 75000 : 1500,
      };
    }
    if (byte === "v" || byte === "j" || byte === "o") {
      assert(this.watch, "probe_watch_missing");
      await this.observe();
      const watch = this.watch;
      this.watch = undefined;
      const durationMs = Math.floor(performance.now() - watch.started);
      assert(
        watch.kind ===
          (byte === "v" ? "renewal" : byte === "o" ? "analog" : "catalog"),
        "probe_watch_kind",
      );
      assert(
        durationMs >= (byte === "v" ? 75000 : 1500) &&
          watch.rotations >= (byte === "v" ? 2 : 0) &&
          watch.samples > 0,
        "probe_hold_insufficient",
      );
      if (byte === "o")
        return {
          analogHeld: true,
          durationMs,
          samples: watch.samples,
          neutralPulses: 0,
          inputTtlMs: 350,
          inputEnabled: false,
        };
      if (byte === "j")
        return {
          catalogHeld: true,
          durationMs,
          samples: watch.samples,
          neutralPulses: 0,
          inputTtlMs: 350,
          inputEnabled: false,
        };
      return {
        continuousHeld: true,
        durationMs,
        rotations: watch.rotations,
        samples: watch.samples,
        neutralPulses: 0,
        inputTtlMs: 350,
        inputEnabled: false,
      };
    }
    if (byte === "c" || byte === "z") {
      let observed: Snapshot | undefined;
      try {
        await this.until(async () => {
          const current = await this.snapshot();
          observed = current;
          if (!current.active || current.reportHex !== NEUTRAL) return false;
          if (byte === "z") return current.sequence === "0";
          const first = records(
            this.local.recordingLog,
            this.activationOffset,
          ).rows.find((row) => row.reason === "sample");
          if (!first) return false;
          assert(first.reportHex === NEUTRAL, "probe_first_sample_not_neutral");
          return true;
        });
      } catch (error) {
        if (
          error instanceof Error &&
          error.message === "probe_condition_timeout"
        )
          throw new Error(
            neutralWaitFailure(
              byte === "c" ? "fresh" : "packet_zero",
              observed,
            ),
          );
        throw error;
      }
      return {
        freshNeutral: true,
        ...(byte === "c" ? { firstSampleNeutral: true } : {}),
      };
    }
    if (byte === "h" || byte === "n") {
      await this.until(async () => {
        const s = await this.snapshot();
        return (
          s.active === (byte === "h") &&
          s.reportHex === (byte === "h" ? SOUTH : NEUTRAL) &&
          (byte === "h" || s.lastReleaseReason === "native_input_released")
        );
      });
      return byte === "h"
        ? { held: true, reportHex: SOUTH, inputEnabled: false }
        : {
            neutral: true,
            reason: "native_input_released",
            inputEnabled: false,
          };
    }
    assert(byte === "f", "probe_command");
    await this.close();
    return { completed: true, inputEnabled: false };
  }
  async close() {
    if (this.closed) return;
    this.closed = true;
    if (this.timer) clearInterval(this.timer);
    await this.gate.settle();
    try {
      if (this.endpoint) await request(this.endpoint, { command: "stop" });
    } catch {}
    if (this.service) {
      const ended = await Promise.race([
        this.service.exited.then(() => true),
        Bun.sleep(5000).then(() => false),
      ]);
      if (!ended) {
        this.service.kill();
        const terminated = await Promise.race([
          this.service.exited.then(() => true),
          Bun.sleep(5000).then(() => false),
        ]);
        if (!terminated) {
          this.service.kill("SIGKILL");
          const killed = await Promise.race([
            this.service.exited.then(() => true),
            Bun.sleep(5000).then(() => false),
          ]);
          assert(killed, "probe_service_cleanup_timeout");
        }
      }
    }
    rmSync(this.parent, { recursive: true, force: true });
  }
}
if (import.meta.main) {
  const probe = new RealServicePhoneProbe();
  const emit = (value: unknown) =>
    process.stdout.write(JSON.stringify(value) + "\n");
  let ending = false;
  const terminate = async () => {
    if (ending) return;
    ending = true;
    try {
      await probe.close();
    } catch {}
    process.exit(1);
  };
  const lifetime = setTimeout(() => void terminate(), 180000);
  process.once("SIGTERM", () => void terminate());
  process.once("SIGINT", () => void terminate());
  try {
    assert(
      process.argv.length <= 3 &&
        process.argv
          .slice(2)
          .every((arg) =>
            [
              "--renewal-watch",
              "--saved-controller",
              "--saved-controller-unsupported",
              "--saved-controller-corner",
              "--saved-controller-analog",
              "--saved-controller-analog-unsupported",
            ].includes(arg),
          ),
      "probe_arguments",
    );
    emit(await probe.start());
    for await (const chunk of Bun.stdin.stream())
      for (const byte of chunk) {
        const command = String.fromCharCode(byte);
        emit(await probe.command(command));
        if (command === "f") process.exit(0);
      }
    throw new Error("probe_stdin_closed");
  } catch (error) {
    const code =
      error instanceof Error && /^probe_[a-z_]{1,96}$/.test(error.message)
        ? error.message
        : error instanceof Error &&
            [
              "service_timeout",
              "service_unavailable",
              "service_disconnected",
              "invalid_service_response",
            ].includes(error.message)
          ? `probe_${error.message}`
          : "probe_real_service_failed";
    process.stderr.write(`Error: "${code}"\n`);
    process.exitCode = 1;
  } finally {
    clearTimeout(lifetime);
    await probe.close();
  }
}
