/** Pure build policy. These commands compile source; they never execute a helper. */
export type CaptureBuild = Readonly<{
  platform: "darwin" | "win32";
  name: "thumble-wow-capture-macos" | "thumble-wow-capture-windows.exe";
  source: string;
  command: readonly string[];
}>;
export function buildOptions(
  arguments_: readonly string[],
  platform: string,
): Readonly<{
  withMacOutput: boolean;
  withPairingQR: boolean;
  capture: CaptureBuild | null;
}> {
  const seen = new Set<string>();
  for (const arg of arguments_) {
    if (
      ![
        "--with-macos-output",
        "--with-wow-capture",
        "--with-pairing-qr",
      ].includes(arg) ||
      seen.has(arg)
    )
      throw new Error("unsupported_build_option");
    seen.add(arg);
  }
  const withPairingQR = seen.has("--with-pairing-qr");
  if (withPairingQR && platform !== "darwin")
    throw new Error("pairing_qr_build_requires_macos");
  const withMacOutput = seen.has("--with-macos-output");
  if (withMacOutput && platform !== "darwin")
    throw new Error("macos_output_build_requires_macos");
  if (!seen.has("--with-wow-capture"))
    return { withMacOutput, withPairingQR, capture: null };
  if (platform !== "darwin" && platform !== "win32")
    throw new Error("wow_capture_build_requires_macos_or_windows");
  return {
    withMacOutput,
    withPairingQR,
    capture:
      platform === "darwin"
        ? {
            platform,
            name: "thumble-wow-capture-macos",
            source:
              "native/wow-capture-macos/.build/release/thumble-wow-capture-macos",
            command: [
              "swift",
              "build",
              "-c",
              "release",
              "--package-path",
              "native/wow-capture-macos",
            ],
          }
        : {
            platform,
            name: "thumble-wow-capture-windows.exe",
            source:
              "native/wow-capture-windows/target/release/thumble-rewrite-wow-capture-windows.exe",
            command: [
              "cargo",
              "+1.88.0",
              "build",
              "--locked",
              "--release",
              "--manifest-path",
              "native/wow-capture-windows/Cargo.toml",
            ],
          },
  };
}
