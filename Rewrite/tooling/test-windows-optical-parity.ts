/** Synthetic pixels only: compile a std-only oracle and compare its entire output to TS. */
import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { decodeWowOpticalPanel } from "../packages/domain/src/wow-optical-panel.ts";
const root = resolve(import.meta.dir, "../..");
const crate = join(root, "Rewrite/native/windows-optical/Cargo.toml");
const work = mkdtempSync(join(tmpdir(), "thumble-optical-parity-"));
try {
  const built = Bun.spawnSync(
    [
      "cargo",
      "+1.88.0",
      "build",
      "--locked",
      "--manifest-path",
      crate,
      "--target-dir",
      work,
      "--example",
      "raster_oracle",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  if (built.exitCode !== 0) throw new Error("optical_oracle_build_failed");
  const oracle = join(
    work,
    "debug/examples/raster_oracle" +
      (process.platform === "win32" ? ".exe" : ""),
  );
  const fixture = JSON.parse(
    readFileSync(
      join(root, "Rewrite/packages/fixtures/wow-live-v1.json"),
      "utf8",
    ),
  );
  const frame = Uint8Array.from(Buffer.from(fixture.frames[0], "hex"));
  let cases = 0;
  function compare(
    width: number,
    height: number,
    stride: number,
    pixels: Uint8Array,
    bgra = false,
    bottom = false,
  ) {
    const normalized = new Uint8Array(stride * height);
    for (let y = 0; y < height; y++)
      for (let x = 0; x < width; x++) {
        const from = (bottom ? height - 1 - y : y) * stride + x * 4,
          to = y * stride + x * 4;
        normalized[to] = pixels[from + (bgra ? 2 : 0)]!;
        normalized[to + 1] = pixels[from + 1]!;
        normalized[to + 2] = pixels[from + (bgra ? 0 : 2)]!;
        normalized[to + 3] = pixels[from + 3]!;
      }
    let expected: Uint8Array;
    try {
      const panel = decodeWowOpticalPanel({
        format: "rgba8",
        width,
        height,
        stride,
        pixels: normalized,
      });
      expected = panel
        ? new Uint8Array([1, ...panel.frame, ...panel.atlas.pixels])
        : new Uint8Array([0]);
    } catch (error) {
      expected = new Uint8Array([
        error instanceof Error && error.message === "wow_optical_scan_limit"
          ? 3
          : 2,
      ]);
    }
    const input = new Uint8Array(20 + pixels.length),
      view = new DataView(input.buffer);
    input.set([84, 87, 79, 80]);
    view.setUint16(4, width, true);
    view.setUint16(6, height, true);
    view.setUint32(8, stride, true);
    input[12] = Number(bgra);
    input[13] = Number(bottom);
    input.set(pixels, 20);
    const result = Bun.spawnSync([oracle], {
      stdin: input,
      stdout: "pipe",
      stderr: "pipe",
    });
    if (
      result.exitCode !== 0 ||
      !Buffer.from(result.stdout).equals(Buffer.from(expected))
    )
      throw new Error(`optical_parity_failed_case_${cases}`);
    cases++;
  }
  function image(scale: number) {
    const width = 1024,
      height = 1100,
      stride = 4096,
      pixels = new Uint8Array(stride * height);
    function rect(x: number, y: number, w: number, h: number, color: number[]) {
      for (
        let row = 23 + Math.floor(y * scale);
        row < 23 + Math.floor((y + h) * scale);
        row++
      )
        for (
          let col = 17 + Math.floor(x * scale);
          col < 17 + Math.floor((x + w) * scale);
          col++
        )
          pixels.set(color, row * stride + col * 4);
    }
    for (let i = 0; i < 4; i++) {
      const color = i % 2 === 0 ? [0, 255, 255, 255] : [255, 0, 255, 255];
      rect(i * 6, 0, 6, 6, color);
      rect(240 + i * 4, 0, 4, 6, color);
    }
    for (let i = 0; i < 16; i++)
      rect(24 + i * 6, 0, 6, 6, [i * 17, i * 17, i * 17, 255]);
    for (let i = 0; i < 1024; i++) {
      const n =
        (i % 2 === 0
          ? frame[Math.floor(i / 2)]! >> 4
          : frame[Math.floor(i / 2)]! & 15) * 17;
      rect((i % 64) * 3, 8 + Math.floor(i / 64) * 3, 3, 3, [n, n, n, 255]);
    }
    for (let i = 0; i < 64; i++)
      rect((i % 8) * 32, 64 + Math.floor(i / 8) * 32, 32, 32, [
        i,
        120,
        240,
        255,
      ]);
    return { width, height, stride, pixels };
  }
  for (const scale of [0.75, 0.853, 1, 1.1, 1.28, 1.5, 1.6, 2, 2.557, 3]) {
    const a = image(scale);
    compare(a.width, a.height, a.stride, a.pixels);
    const stride = a.stride + 16,
      padded = new Uint8Array(stride * a.height).fill(19);
    for (let y = 0; y < a.height; y++)
      for (let x = 0; x < a.width; x++) {
        const from = y * a.stride + x * 4,
          to = (a.height - 1 - y) * stride + x * 4;
        padded.set(
          [
            a.pixels[from + 2]!,
            a.pixels[from + 1]!,
            a.pixels[from]!,
            a.pixels[from + 3]!,
          ],
          to,
        );
      }
    compare(a.width, a.height, stride, padded, true, true);
  }
  const corrupt = image(1);
  corrupt.pixels[(32 * 1024 + 18) * 4] =
    corrupt.pixels[(32 * 1024 + 18) * 4]! ^ 127;
  compare(corrupt.width, corrupt.height, corrupt.stride, corrupt.pixels);
  compare(1, 1, 4, new Uint8Array(4));
  compare(1024, 200, 4096, image(1).pixels.slice(0, 4096 * 200));
  const width = 8192,
    height = 64,
    stride = width * 4,
    adversarial = new Uint8Array(stride * height);
  for (let y = 0; y < height; y += 2) {
    for (let marker = 0; marker < 4; marker++)
      for (let x = 17 + marker * 6; x < 17 + (marker + 1) * 6; x++)
        adversarial.set(
          marker % 2 === 0 ? [0, 255, 255, 255] : [255, 0, 255, 255],
          y * stride + x * 4,
        );
    for (let x = 200; x < width; x++)
      adversarial.set([0, 255, 255, 255], y * stride + x * 4);
  }
  compare(width, height, stride, adversarial);
  console.log(
    JSON.stringify({
      kind: "synthetic-optical-ts-rust-parity",
      cases,
      realCapture: false,
      windowsApiUsed: false,
    }),
  );
} finally {
  rmSync(work, { recursive: true, force: true });
}
