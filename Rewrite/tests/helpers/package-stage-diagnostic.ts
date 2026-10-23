/** Test-only opt-in evidence. Never accepts child output, arguments or identifiers. */
const stages = new Set([
  "file-probe",
  "import-probe",
  "configuration-seed",
  "configuration-probe",
  "pairing-peer",
  "mcp-probe",
  "configuration-reopen",
  "cleanup",
  "identity-initialize",
  "identity-show",
  "service-start",
  "service-status",
  "service-stop",
  "pairing-open",
  "pairing-status",
  "pairing-cancel",
  "pairing-listen",
  "pairing-list",
  "pairing-revoke",
  "pairing-stop-listening",
  "configuration-list",
  "configuration-rename-profile",
]);
const phases = new Set(["begin", "stdout", "stderr", "exit", "end", "error"]);
export class PackageStageDiagnostic {
  private readonly started: number;
  private count = 0;
  private bytes = 0;
  constructor(
    private readonly enabled = process.env
      .THUMBLE_REWRITE_PACKAGE_STAGE_PROBE === "1",
    private readonly emit: (line: string) => void = (line) =>
      console.error(line),
    private readonly now: () => number = () => performance.now(),
  ) {
    this.started = enabled ? now() : 0;
  }
  event(stage: string, phase: string): void {
    if (
      !this.enabled ||
      !stages.has(stage) ||
      !phases.has(phase) ||
      this.count >= 192
    )
      return;
    try {
      const elapsedMs = Math.min(
        60000,
        Math.max(0, Math.floor(this.now() - this.started)),
      );
      if (!Number.isFinite(elapsedMs)) return;
      const line =
        "package_stage " +
        JSON.stringify({ version: 1, stage, phase, elapsedMs });
      if (line.length > 192 || this.bytes + line.length + 1 > 32768) return;
      this.count++;
      this.bytes += line.length + 1;
      this.emit(line);
    } catch {
      /* Optional evidence cannot affect the tested operation. */
    }
  }
  async run<T>(stage: string, operation: () => Promise<T>): Promise<T> {
    this.event(stage, "begin");
    try {
      const result = await operation();
      this.event(stage, "end");
      return result;
    } catch (error) {
      this.event(stage, "error");
      throw error;
    }
  }
  async settled<T>(
    stage: string,
    phase: "stdout" | "stderr" | "exit",
    value: Promise<T>,
  ): Promise<T> {
    const result = await value;
    this.event(stage, phase);
    return result;
  }
}

/** Strict canonical schema for retaining a sanitized CI artifact. */
export function decodePackageStageLine(line: string): string | undefined {
  if (
    line.length > 192 ||
    !/^[\x20-\x7e]*$/.test(line) ||
    !line.startsWith("package_stage ")
  )
    return;
  const text = line.slice("package_stage ".length);
  try {
    const row = JSON.parse(text);
    if (
      !row ||
      typeof row !== "object" ||
      Array.isArray(row) ||
      Object.keys(row).sort().join(",") !== "elapsedMs,phase,stage,version" ||
      row.version !== 1 ||
      !stages.has(row.stage) ||
      !phases.has(row.phase) ||
      !Number.isInteger(row.elapsedMs) ||
      row.elapsedMs < 0 ||
      row.elapsedMs > 60000
    )
      return;
    const canonical = JSON.stringify({
      version: 1,
      stage: row.stage,
      phase: row.phase,
      elapsedMs: row.elapsedMs,
    });
    return canonical === text ? "package_stage " + canonical : undefined;
  } catch {
    return;
  }
}
export function collectPackageStageLines(text: string): string {
  const rows: string[] = [];
  let bytes = 0;
  for (const source of text.slice(0, 65536).split(/\r?\n/)) {
    const line = decodePackageStageLine(source);
    if (line && rows.length < 192 && bytes + line.length + 1 <= 32768) {
      rows.push(line);
      bytes += line.length + 1;
    }
  }
  return rows.map((line) => line + "\n").join("");
}
