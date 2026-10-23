import { deflateSync } from "node:zlib";
import { expect, test } from "bun:test";
import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import {
  exportPairingQR,
  validatePairingQRDestination,
  validatePairingQRPNG,
} from "../apps/cli/src/pairing-qr.ts";
import { buildOptions } from "../tooling/build-options.ts";
import { packagePairingQR } from "../tooling/package-pairing-qr.ts";
import type { PairingReply } from "@thumble/contracts/pairing";
const root = resolve(import.meta.dir, ".."),
  helper = join(
    root,
    "native/pairing-qr-macos/.build/release/thumble-pairing-qr-macos",
  );
const offer = {
  authorityInstanceId: "synthetic-authority",
  certificatePin: "a".repeat(64),
  expiresAt: 9007199254740991,
  host: "192.0.2.10",
  port: 65535,
  secret: "b".repeat(64),
  windowId: "synthetic-window",
};
const reply: PairingReply = {
  authorityInstanceId: offer.authorityInstanceId,
  offer,
  pairing: {
    state: "open",
    windowId: offer.windowId,
    expiresAt: offer.expiresAt,
    attemptsRemaining: 5,
    networkEnabled: true,
  },
};
const fixture = (run: (dir: string) => void) => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "thumble-qr-")));
  try {
    run(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
};

test("QR build is opt-in Mac-only and optional artifact assembly never executes source", () =>
  fixture((dir) => {
    expect(
      buildOptions(
        ["--with-pairing-qr", "--with-wow-capture", "--with-macos-output"],
        "darwin",
      ).withPairingQR,
    ).toBe(true);
    for (const p of ["linux", "win32"])
      expect(() => buildOptions(["--with-pairing-qr"], p)).toThrow(
        "pairing_qr_build_requires_macos",
      );
    expect(() =>
      buildOptions(["--with-pairing-qr", "--with-pairing-qr"], "darwin"),
    ).toThrow("unsupported_build_option");
    const source = join(dir, "native/pairing-qr-macos/.build/release");
    mkdirSync(source, { recursive: true });
    writeFileSync(
      join(source, "thumble-pairing-qr-macos"),
      "owned fake binary",
    );
    packagePairingQR(dir, true);
    const manifest = JSON.parse(
      readFileSync(join(dir, "dist/PAIRING-QR-MANIFEST.json"), "utf8"),
    );
    expect(manifest.helperExecuted).toBe(false);
    expect(manifest.pairingOpened).toBe(false);
    expect(
      readFileSync(join(dir, "dist/thumble-pairing-qr-macos"), "utf8"),
    ).toBe("owned fake binary");
    packagePairingQR(dir, false);
    expect(existsSync(join(dir, "dist/thumble-pairing-qr-macos"))).toBe(false);
  }));

test("QR destinations reject unsupported platforms, relative paths and overwrite before pairing", () =>
  fixture((dir) => {
    expect(() =>
      validatePairingQRDestination("/tmp/new", "/tmp/helper", "linux"),
    ).toThrow("pairing_qr_requires_macos");
    expect(() =>
      validatePairingQRDestination("relative", "/tmp/helper", "darwin"),
    ).toThrow("pairing_qr_absolute_path_required");
    writeFileSync(join(dir, "keep.png"), "keep");
    expect(() =>
      validatePairingQRDestination(
        join(dir, "keep.png"),
        "/tmp/helper",
        "darwin",
      ),
    ).toThrow("pairing_qr_destination_exists");
    expect(() => validatePairingQRPNG(Buffer.from("bad"))).toThrow(
      "pairing_qr_invalid_png",
    );
  }));

if (
  process.platform === "darwin" &&
  process.env.THUMBLE_REWRITE_PAIRING_QR_TEST === "1"
) {
  test(
    "native QR creates exact-invitation PNG with0600, refuses files/symlinks and bounds helper failures",
    () =>
      fixture((dir) => {
        const png = join(dir, "pairing.png"),
          artifact = exportPairingQR(reply, png, helper);
        expect(artifact.containsPairingSecret).toBe(true);
        expect(artifact.sha256).toMatch(/^[0-9a-f]{64}$/);
        expect(statSync(png).mode & 0o777).toBe(0o600);
        const bytes = readFileSync(png);
        validatePairingQRPNG(bytes);
        const corrupt = Buffer.from(bytes);
        corrupt[corrupt.length - 5] = corrupt[corrupt.length - 5]! ^ 1;
        expect(() => validatePairingQRPNG(corrupt)).toThrow(
          "pairing_qr_invalid_png",
        );
        expect(() => exportPairingQR(reply, png, helper)).toThrow(
          "pairing_qr_destination_exists",
        );
        symlinkSync(png, join(dir, "link.png"));
        expect(() =>
          exportPairingQR(reply, join(dir, "link.png"), helper),
        ).toThrow("pairing_qr_destination_exists");
        expect(() =>
          exportPairingQR(
            { ...reply, offer: null },
            join(dir, "no-listener.png"),
            helper,
          ),
        ).toThrow("pairing_qr_listener_required");
        const compile = Bun.spawnSync(
          [
            process.execPath,
            "build",
            "--compile",
            join(root, "tests/fixtures/pairing-qr-helper.ts"),
            "--outfile",
            join(dir, "fake"),
          ],
          { stdout: "pipe", stderr: "pipe" },
        );
        expect(compile.exitCode).toBe(0);
        process.env.THUMBLE_QR_TEST_PNG = png;
        try {
          for (const [mode, code] of [
            ["error", "pairing_qr_helper_failed"],
            ["large", "pairing_qr_helper_failed"],
            ["invalid", "pairing_qr_invalid_png"],
            ["timeout", "pairing_qr_timeout"],
          ] as const) {
            const fake = join(dir, `fake-${mode}`);
            copyFileSync(join(dir, "fake"), fake);
            let error: unknown;
            try {
              exportPairingQR(reply, join(dir, `${mode}.png`), fake);
            } catch (failure) {
              error = failure;
            }
            expect(error instanceof Error ? error.message : null).toBe(code);
            expect(existsSync(join(dir, `${mode}.png`))).toBe(false);
          }
        } finally {
          delete process.env.THUMBLE_QR_TEST_PNG;
        }
      }),
    20000,
  );

  test(
    "real pairing CLI reveal opt-in exports exact native7field invitation, Vision decodes and output stays inactive",
    () =>
      fixture((dir) => {
        const cli = join(root, "apps/cli/src/main.ts"),
          receiver = join(
            root,
            "native/receiver/target/debug/thumble-rewrite-receiver",
          );
        const common = [
          "--runtime-dir",
          join(dir, "runtime"),
          "--receiver",
          receiver,
        ];
        function invoke(family: string, action: string, flags: string[] = []) {
          const p = Bun.spawnSync(
            [process.execPath, cli, family, action, ...common, ...flags],
            { stdout: "pipe", stderr: "pipe", timeout: 10000 },
          );
          const parsed = JSON.parse(p.stdout.toString());
          if (
            p.exitCode !==
            (flags.includes("--reveal-secret") || family !== "pairing" ? 0 : 1)
          )
            throw new Error(
              typeof parsed.error === "string" && /^[a-z_]+$/.test(parsed.error)
                ? parsed.error
                : "qr_cli_failed",
            );
          expect(p.stderr.length).toBe(0);
          return JSON.parse(p.stdout.toString());
        }
        const identity = join(dir, "identity");
        const initialized = Bun.spawnSync(
          [receiver, "host-identity-initialize", identity],
          { stdout: "pipe", stderr: "pipe", timeout: 5000 },
        );
        expect(initialized.exitCode).toBe(0);
        invoke("service", "start", ["--identity-dir", identity]);
        try {
          const denied = invoke("pairing", "listen", [
            "--bind-address",
            "127.0.0.1:0",
            "--advertise-host",
            "127.0.0.1",
            "--qr-output",
            join(dir, "denied.png"),
            "--qr-helper",
            helper,
          ]);
          expect(denied.ok).toBe(false);
          expect(denied.error).toBe("pairing_secret_output_opt_in_required");
          expect(existsSync(join(dir, "denied.png"))).toBe(false);
          const png = join(dir, "listen.png"),
            response = invoke("pairing", "listen", [
              "--bind-address",
              "127.0.0.1:0",
              "--advertise-host",
              "127.0.0.1",
              "--reveal-secret",
              "--qr-output",
              png,
              "--qr-helper",
              helper,
            ]);
          expect(response.ok).toBe(true);
          const offer = response.result.offer;
          expect(Object.keys(offer).length).toBe(7);
          expect(offer.host).toBe("127.0.0.1");
          const expected = JSON.stringify({
            authorityInstanceId: offer.authorityInstanceId,
            certificatePin: offer.certificatePin,
            expiresAt: offer.expiresAt,
            host: offer.host,
            port: offer.port,
            secret: offer.secret,
            windowId: offer.windowId,
          });
          const witness = Bun.spawnSync(
            ["swift", join(root, "tooling/verify-pairing-qr.swift"), png],
            {
              stdin: Buffer.from(expected),
              stdout: "pipe",
              stderr: "pipe",
              timeout: 20000,
            },
          );
          expect(witness.exitCode).toBe(0);
          expect(witness.stdout.toString().trim()).toBe("qr_verified");
          // Vision/toolchain diagnostics are not the witness protocol. Exact decoded
          // stdout and exit status above remain required; never print invitation data.
          expect(witness.stderr.length).toBeLessThanOrEqual(4096);
          const opened = invoke("pairing", "open", [
            "--reveal-secret",
            "--qr-output",
            join(dir, "open.png"),
            "--qr-helper",
            helper,
          ]);
          expect(opened.ok).toBe(true);
          expect(opened.result.offer.host).toBe("127.0.0.1");
          expect(
            invoke("receiver", "status").result.receiver.snapshot.active,
          ).toBe(false);
        } finally {
          invoke("service", "stop");
        }
      }),
    30000,
  );
}

test("QR PNG validation rejects CRC-valid invalid deflate and oversized decoded scanlines", () => {
  function chunk(name: string, data: Buffer): Buffer {
    const type = Buffer.from(name),
      length = Buffer.alloc(4),
      sum = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    let crc = 0xffffffff;
    for (const byte of Buffer.concat([type, data])) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++)
        crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
    sum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([length, type, data, sum]);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(232, 0);
  header.writeUInt32BE(232, 4);
  header[8] = 8;
  header[9] = 6;
  const png = (data: Buffer) =>
    Buffer.concat([
      Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
      chunk("IHDR", header),
      chunk("IDAT", data),
      chunk("IEND", Buffer.alloc(0)),
    ]);
  for (const data of [
    Buffer.from("invalid zlib"),
    deflateSync(Buffer.alloc((232 * 4 + 1) * 232 + 1)),
  ])
    expect(() => validatePairingQRPNG(png(data))).toThrow(
      "pairing_qr_invalid_png",
    );
});
