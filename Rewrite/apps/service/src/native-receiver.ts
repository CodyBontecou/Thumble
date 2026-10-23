import {
  decodeSavedBinding,
  decodeSavedRearmStatus,
  type SavedRearmStatus,
  type SavedRuntimeBinding,
} from "@thumble/contracts/saved-runtime";
import {
  decodeSnapshot,
  exact,
  type ReceiverCommand,
  type Snapshot,
} from "@thumble/contracts/receiver";
import type { ReceiverPort } from "@thumble/application";
import { NativePipe } from "./native-pipe.ts";
export type ReceiverOutput =
  | Readonly<{ backend: "recording" }>
  | Readonly<{ backend: "macos-hid"; allowPhysicalOutput: true }>;

export class NativeReceiver implements ReceiverPort {
  private readonly pipe: NativePipe<
    Snapshot,
    | Snapshot
    | SavedRearmStatus
    | { snapshot: Snapshot; savedBinding: SavedRuntimeBinding | null }
  >;
  get child() {
    return this.pipe.child;
  }
  get ready() {
    return this.pipe.ready;
  }
  constructor(
    executable: string,
    directory: string,
    recordingLog: string,
    output: ReceiverOutput = { backend: "recording" },
  ) {
    if (
      output.backend !== "recording" &&
      !(output.backend === "macos-hid" && output.allowPhysicalOutput === true)
    )
      throw new Error("physical_output_explicit_flag_required");
    const backend = output.backend;
    const snapshot = (value: unknown): Snapshot => {
      const decoded = decodeSnapshot(value);
      if (decoded.backend !== backend)
        throw new Error("receiver_backend_mismatch");
      return decoded;
    };
    this.pipe = new NativePipe(
      executable,
      backend === "recording"
        ? ["run", directory, recordingLog]
        : ["run-macos-hid", directory, "--allow-physical-output"],
      {
        ready(value, pid) {
          exact(value, ["version", "ready", "pid", "snapshot"]);
          if (value.version !== 1 || value.ready !== true || value.pid !== pid)
            throw new Error("invalid_ready");
          return snapshot(value.snapshot);
        },
        reply(value) {
          if (Object.hasOwn(value, "cleanupReady")) {
            exact(value, [
              "version",
              "requestId",
              "ok",
              "snapshot",
              "releasedBinding",
              "cleanupReady",
              "firstTermination",
            ]);
            return decodeSavedRearmStatus({
              snapshot: snapshot(value.snapshot),
              releasedBinding: value.releasedBinding,
              cleanupReady: value.cleanupReady,
              firstTermination: value.firstTermination,
            });
          }
          if (Object.hasOwn(value, "savedBinding")) {
            exact(value, [
              "version",
              "requestId",
              "ok",
              "snapshot",
              "savedBinding",
            ]);
            const decoded = snapshot(value.snapshot);
            return {
              snapshot: decoded,
              savedBinding: decodeSavedBinding(value.savedBinding, decoded),
            };
          }
          exact(value, ["version", "requestId", "ok", "snapshot"]);
          return snapshot(value.snapshot);
        },
      },
      "receiver_unavailable",
    );
  }
  async request(body: ReceiverCommand): Promise<Snapshot> {
    const reply = await this.pipe.request(body);
    if ("snapshot" in reply) {
      this.pipe.disconnect();
      throw new Error("receiver_response_invalid");
    }
    return reply;
  }
  async savedStatus(): Promise<{
    snapshot: Snapshot;
    savedBinding: SavedRuntimeBinding | null;
  }> {
    const reply = await this.pipe.request({ command: "savedBindingStatus" });
    if (!("snapshot" in reply)) {
      this.pipe.disconnect();
      throw new Error("receiver_response_invalid");
    }
    if (!("savedBinding" in reply)) {
      this.pipe.disconnect();
      throw new Error("receiver_response_invalid");
    }
    return reply;
  }
  async rearmStatus(): Promise<SavedRearmStatus> {
    const reply = await this.pipe.request({ command: "savedRearmStatus" });
    if (!("cleanupReady" in reply)) {
      this.pipe.disconnect();
      throw new Error("receiver_response_invalid");
    }
    return reply;
  }
  disconnect(): void {
    this.pipe.disconnect();
  }
}
