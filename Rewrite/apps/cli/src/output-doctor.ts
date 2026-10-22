import { spawn } from "node:child_process";
import {
  decodeOutputCapabilities,
  type OutputCapabilities,
} from "@thumble/contracts/output-capabilities";
import { parseStrictJson } from "@thumble/contracts/receiver";
/** Offline bounded native inspection; no service endpoint or state directory. */
export function inspectOutputCapabilities(
  receiver: string,
): Promise<OutputCapabilities> {
  return new Promise((resolve, reject) => {
    const child = spawn(receiver, ["output-capabilities"], {
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    const chunks: Buffer[] = [];
    let stdoutBytes = 0,
      stderrBytes = 0,
      settled = false;
    const finish = (error?: string, value?: OutputCapabilities) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) {
        child.kill("SIGKILL");
        reject(new Error(error));
      } else resolve(value!);
    };
    const timer = setTimeout(() => finish("output_doctor_timeout"), 3000);
    child.on("error", () => finish("output_doctor_unavailable"));
    child.stdout.on("data", (chunk: Buffer) => {
      stdoutBytes += chunk.length;
      if (stdoutBytes > 4096) {
        finish("output_doctor_response_too_large");
        return;
      }
      chunks.push(Buffer.from(chunk));
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderrBytes += chunk.length;
      if (stderrBytes > 4096) finish("output_doctor_unavailable");
    });
    child.on("close", (code) => {
      if (settled) return;
      if (code !== 0 || stderrBytes !== 0) {
        finish("output_doctor_unavailable");
        return;
      }
      try {
        finish(
          undefined,
          decodeOutputCapabilities(
            parseStrictJson(
              new TextDecoder("utf-8", { fatal: true }).decode(
                Buffer.concat(chunks),
              ),
            ),
          ),
        );
      } catch {
        finish("output_doctor_response_invalid");
      }
    });
  });
}
