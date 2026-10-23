#!/usr/bin/env bun
/** Synthetic recording-only integration peer; no game, capture or physical output. */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, statSync, writeFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { createHash } from "node:crypto";
import { deflateSync } from "node:zlib";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import {
  readEndpoint,
  requestConfiguration,
  requestPairing,
  requestSavedRuntime,
  requestSavedReadiness,
} from "@thumble/client/local";
import { parseStrictJson } from "@thumble/contracts/receiver";
import { RealServicePhoneProbe, SECOND } from "./real-service-phone-probe.ts";
const ROOT = resolve(import.meta.dir, "..");
const SOUTH = "ce000000-0000-0000-0000-00000000000a";
function object(value: unknown): Record<string, unknown> {
  assert(
    value !== null && typeof value === "object" && !Array.isArray(value),
    "presentation_probe_object",
  );
  return value as Record<string, unknown>;
}
function png(color: number): Uint8Array {
  function chunk(name: string, data: Buffer): Buffer {
    const out = Buffer.alloc(data.length + 12);
    out.writeUInt32BE(data.length);
    out.write(name, 4, "ascii");
    data.copy(out, 8);
    let crc = 0xffffffff;
    for (const byte of out.subarray(4, -4)) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++)
        crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
    out.writeUInt32BE((crc ^ 0xffffffff) >>> 0, out.length - 4);
    return out;
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(32);
  header.writeUInt32BE(32, 4);
  header[8] = 8;
  header[9] = 6;
  const scan = Buffer.alloc(32 * 129);
  for (let y = 0; y < 32; y++)
    for (let x = 0; x < 32; x++) {
      const at = y * 129 + 1 + x * 4;
      scan[at] = color;
      scan[at + 1] = 64;
      scan[at + 2] = 192 - color;
      scan[at + 3] = 255;
    }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(scan)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
export function syntheticSource(
  color: number,
  name: string,
  centerX = 0.5,
): string {
  const source = JSON.parse(
    starterConfiguration(SECOND, "Presentation witness", "1").text(),
  );
  const profile = source.profiles[0];
  const south = profile.customization.elements.find(
    (element: { id: string }) => element.id === SOUTH,
  );
  assert(south, "presentation_probe_south");
  south.label = name;
  south.layout.centerX = centerX;
  south.layout.centerY = 0.5;
  profile.customization.elements = [south];
  source.outputBindings = { [SOUTH]: source.outputBindings[SOUTH] };
  source.profileOutputBindings = { [SECOND]: source.outputBindings };
  const bytes = png(color);
  const variants = [];
  for (const colorScheme of ["light", "dark"])
    for (const actionSet of [
      "base",
      "left-trigger",
      "right-trigger",
      "both-triggers",
    ])
      variants.push({
        colorScheme,
        actionSet,
        appearance: {
          accentStyle: "blue",
          showsButtonLabels: true,
          topBar: {},
          controlBar: {},
          controls: {
            [SOUTH]: {
              icon: {
                source: "asset",
                value: "synthetic-icon",
                placement: "top",
                renderingMode: "original",
                scale: 1,
              },
            },
          },
          artworkLayers: [],
          styleLibrary: { styles: [] },
          assetLibrary: {
            assets: [
              {
                id: "synthetic-icon",
                name,
                role: "icon",
                contentType: "image/png",
                byteCount: bytes.length,
                data: Buffer.from(bytes).toString("base64"),
              },
            ],
          },
        },
      });
  profile.appearanceBank = { schemaVersion: 1, variants };
  return JSON.stringify(source);
}
export function syntheticBankSource(refreshed = false): string {
  const source = JSON.parse(
    syntheticSource(
      refreshed ? 144 : 24,
      refreshed ? "Refreshed spell" : "Initial spell",
    ),
  );
  const profile = source.profiles[0];
  const starter = JSON.parse(
    starterConfiguration(SECOND, "Presentation witness", "1").text(),
  );
  const triggers = starter.profiles[0].customization.elements.filter(
    (e: { kind: string }) => e.kind === "trigger",
  );
  assert(triggers.length === 2, "presentation_probe_triggers");
  profile.customization.elements.push(...triggers);
  const variants = profile.appearanceBank.variants;
  for (let index = 0; index < variants.length; index++) {
    const variant = variants[index];
    const bytes = png((refreshed ? 112 : 16) + index * 8);
    const asset = variant.appearance.assetLibrary.assets[0];
    asset.name = `${refreshed ? "Refreshed" : "Initial"} ${variant.colorScheme} ${variant.actionSet}`;
    asset.byteCount = bytes.length;
    asset.data = Buffer.from(bytes).toString("base64");
  }
  // Canonical mirrors deliberately equal saved light/base: selecting another bank
  // must use that variant rather than interpret a missing mirror as icon removal.
  profile.customization.assetLibrary = variants[0].appearance.assetLibrary;
  profile.customization.elements[0].layout.icon =
    variants[0].appearance.controls[SOUTH].icon;
  return JSON.stringify(source);
}
export class PresentationServiceProbe {
  private readonly probe: RealServicePhoneProbe;
  private serial = 0;
  private readonly bankMode = process.argv.includes("--bank-presentation");
  private bankWatch:
    | { started: number; offset: number; generation: string; revision: string }
    | undefined;
  private phase = "base_start";
  diagnosticPhase() {
    return this.phase;
  }
  constructor() {
    // Existing public probe's saved-mode selector is fixed synthetic QA input only.
    if (!process.argv.includes("--saved-controller"))
      process.argv.push("--saved-controller");
    this.probe = new RealServicePhoneProbe();
  }
  private get endpoint() {
    return readEndpoint(this.probe.directory, this.probe.receiver);
  }
  private cli(
    family: string,
    action: string,
    flags: string[] = [],
  ): Record<string, unknown> {
    this.phase =
      action === "validate-file"
        ? "validate_file"
        : action === "import-file"
          ? "import_file"
          : "import_status";
    const output = execFileSync(
      process.execPath,
      [
        resolve(ROOT, "apps/cli/src/main.ts"),
        family,
        action,
        ...(action === "validate-file"
          ? []
          : [
              "--runtime-dir",
              this.probe.directory,
              "--receiver",
              this.probe.receiver,
            ]),
        "--json",
        ...flags,
      ],
      { timeout: 5000, maxBuffer: 65536, stdio: ["ignore", "pipe", "pipe"] },
    );
    const reply = object(parseStrictJson(output.toString("utf8")));
    assert(reply.ok === true, "presentation_probe_cli");
    return object(reply.result);
  }
  private async catalog() {
    return object(
      await requestConfiguration(this.endpoint, {
        command: "configuration-list",
        expectedRevision: null,
        offset: 0,
      }),
    );
  }
  private async install(
    color: number,
    name: string,
    centerX = 0.5,
    bankRefresh?: boolean,
  ) {
    const current = await this.catalog();
    assert(typeof current.revision === "string", "presentation_probe_revision");
    const path = join(this.probe.parent, "synthetic-presentation.json");
    writeFileSync(
      path,
      bankRefresh === undefined
        ? syntheticSource(color, name, centerX)
        : syntheticBankSource(bankRefresh),
      { mode: 0o600 },
    );
    const inspected = this.cli("configuration", "validate-file", [
      "--file",
      path,
    ]);
    assert(
      typeof inspected.contentHash === "string",
      "presentation_probe_hash",
    );
    const flags = [
      "--operation-id",
      `presentation-${++this.serial}`,
      "--expected-revision",
      current.revision,
      "--expected-source-hash",
      inspected.contentHash,
    ];
    this.cli("configuration", "import-file", [...flags, "--file", path]);
    const deadline = performance.now() + 5000;
    for (;;) {
      const status = this.cli("configuration", "import-status", flags);
      if (status.kind === "import-committed") break;
      assert(
        status.kind === "import-pending" && performance.now() < deadline,
        "presentation_probe_import",
      );
      await Bun.sleep(5);
    }
    const catalog = await this.catalog();
    return {
      configurationRevision: catalog.revision,
      sourceHash: catalog.contentHash,
      iconSHA256: createHash("sha256").update(png(color)).digest("hex"),
      label: name,
    };
  }
  async start() {
    const offer = await this.probe.start();
    this.phase = "seed";
    const installed = await this.install(
      24,
      "Initial spell",
      0.5,
      this.bankMode ? false : undefined,
    );
    return { ...offer, profileCount: 1, ...installed, southId: SOUTH };
  }
  async command(byte: string): Promise<Record<string, unknown>> {
    this.phase = [
      "a",
      "z",
      "q",
      "u",
      "s",
      "j",
      "n",
      "f",
      "x",
      "r",
      "p",
      "c",
      "d",
      "w",
      "g",
      "m",
      "i",
    ].includes(byte)
      ? `command_${byte}`
      : "invalid_command";
    if (byte === "w" || byte === "g") {
      assert(this.bankMode, "presentation_probe_bank_mode");
      const expected = "00140010ffff0000000000000000000000000000";
      const deadline = performance.now() + 1000;
      let { snapshot } = await requestSavedRuntime(this.endpoint, {
        command: "saved-binding-status",
      });
      while (
        byte === "w" &&
        snapshot.active &&
        snapshot.reportHex !== expected &&
        performance.now() < deadline
      ) {
        await Bun.sleep(5);
        ({ snapshot } = await requestSavedRuntime(this.endpoint, {
          command: "saved-binding-status",
        }));
      }
      assert(
        snapshot.backend === "recording" &&
          !snapshot.inputEnabled &&
          snapshot.active &&
          snapshot.reportHex === expected,
        "presentation_probe_bank_held",
      );
      if (byte === "w") {
        this.bankWatch = {
          started: performance.now(),
          offset: statSync(this.endpoint.recordingLog).size,
          generation: snapshot.generation,
          revision: snapshot.revision,
        };
        return { watching: true };
      }
      const watch = this.bankWatch;
      assert(
        watch && performance.now() - watch.started >= 1500,
        "presentation_probe_bank_hold_short",
      );
      assert(
        statSync(this.endpoint.recordingLog).size <= 4194304,
        "presentation_probe_bank_log_bound",
      );
      const bytes = readFileSync(this.endpoint.recordingLog);
      assert(
        bytes.length - watch.offset <= 2097152,
        "presentation_probe_bank_log_bound",
      );
      const tail = bytes.subarray(watch.offset);
      const end = tail.lastIndexOf(10);
      assert(end >= 0, "presentation_probe_bank_no_samples");
      const rows = tail
        .subarray(0, end)
        .toString("utf8")
        .split("\n")
        .map((line) => object(parseStrictJson(line)));
      assert(
        rows.length > 0 &&
          rows.every(
            (row) => row.reason === "sample" && row.reportHex === expected,
          ),
        "presentation_probe_bank_interrupted",
      );
      assert(
        snapshot.generation === watch.generation &&
          snapshot.revision === watch.revision,
        "presentation_probe_bank_epochs",
      );
      return {
        bankHeld: true,
        samples: rows.length,
        neutralPulses: 0,
        inputTtlMs: 350,
        inputEnabled: snapshot.inputEnabled,
      };
    }
    if (byte === "i") {
      const [{ snapshot }, readiness] = await Promise.all([
        requestSavedRuntime(this.endpoint, { command: "saved-binding-status" }),
        requestSavedReadiness(this.endpoint),
      ]);
      return {
        active: snapshot.active,
        generation: snapshot.generation,
        revision: snapshot.revision,
        reason: snapshot.lastReleaseReason,
        firstReason: readiness.firstTermination?.reason ?? "none",
        firstGeneration: readiness.firstTermination?.generation ?? "0",
        firstRevision: readiness.firstTermination?.revision ?? "0",
      };
    }
    if (byte === "d") {
      const { snapshot } = await requestSavedRuntime(this.endpoint, {
        command: "saved-binding-status",
      });
      return {
        active: snapshot.active,
        generation: snapshot.generation,
        revision: snapshot.revision,
        reason: snapshot.lastReleaseReason,
      };
    }
    if (byte === "u" || byte === "s" || byte === "m") {
      if (byte === "m") assert(this.bankMode, "presentation_probe_bank_mode");
      const before = await requestSavedRuntime(this.endpoint, {
        command: "saved-binding-status",
      });
      assert(
        before.savedBinding && before.snapshot.active,
        "presentation_probe_unbound",
      );
      const refreshed = await this.install(
        144,
        "Refreshed spell",
        byte === "s" ? 0.6 : 0.5,
        byte === "m" ? true : undefined,
      );
      const after = await requestSavedRuntime(this.endpoint, {
        command: "saved-binding-status",
      });
      assert(
        after.savedBinding &&
          after.snapshot.active &&
          JSON.stringify(after.savedBinding) ===
            JSON.stringify(before.savedBinding),
        "presentation_probe_changed_binding",
      );
      return {
        ...(byte === "s" ? { staleSource: true } : { refreshed: true }),
        ...refreshed,
        generation: after.snapshot.generation,
        revision: after.snapshot.revision,
      };
    }
    if (byte === "x") {
      const current = await this.catalog();
      assert(
        typeof current.revision === "string" && BigInt(current.revision) > 0n,
        "presentation_probe_revision",
      );
      const result = object(
        await requestConfiguration(this.endpoint, {
          command: "configuration-rename-profile",
          operationId: "presentation-stale-cas",
          expectedRevision: (BigInt(current.revision) - 1n).toString(),
          profileId: SECOND,
          name: "Must not commit",
        }),
      );
      assert(result.kind === "conflict", "presentation_probe_cas");
      return { casRejected: true };
    }
    if (byte === "p") {
      const opened = await requestPairing(this.endpoint, {
        command: "pairing-open",
      });
      assert(opened.offer, "presentation_probe_offer");
      return {
        windowId: opened.offer.windowId,
        secret: opened.offer.secret,
        expiresAt: opened.offer.expiresAt,
      };
    }
    if (byte === "r") {
      await requestPairing(this.endpoint, {
        command: "pairing-revoke",
        phoneId: "phone-b",
      });
      return { secondaryRevoked: true };
    }
    if (byte === "c") {
      const c = await this.catalog();
      return {
        configurationRevision: c.revision,
        sourceHash: c.contentHash,
        profileId: c.activeProfileId,
      };
    }
    assert(
      ["a", "z", "q", "j", "n", "f"].includes(byte),
      "presentation_probe_command",
    );
    return this.probe.command(byte);
  }
  close() {
    return this.probe.close();
  }
}
if (import.meta.main) {
  const probe = new PresentationServiceProbe();
  let closing = false;
  const terminate = async (code: number) => {
    if (closing) return;
    closing = true;
    try {
      await probe.close();
    } catch {}
    process.exit(code);
  };
  const timer = setTimeout(() => void terminate(1), 60000);
  process.once("SIGTERM", () => void terminate(1));
  process.once("SIGINT", () => void terminate(1));
  try {
    process.stdout.write(JSON.stringify(await probe.start()) + "\n");
    for await (const bytes of Bun.stdin.stream())
      for (const byte of bytes) {
        const command = String.fromCharCode(byte);
        process.stdout.write(
          JSON.stringify(await probe.command(command)) + "\n",
        );
        if (command === "f") {
          clearTimeout(timer);
          process.exit(0);
        }
      }
    throw Error("presentation_probe_eof");
  } catch (error) {
    const code =
      error instanceof Error &&
      /^(?:probe|presentation_probe)_[a-z_]{1,96}$/.test(error.message)
        ? error.message
        : "unclassified";
    process.stderr.write(
      `presentation_probe_failed_${probe.diagnosticPhase()}_${code}\n`,
    );
    await terminate(1);
  }
}
