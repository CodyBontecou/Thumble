import {
  decodeSavedBinding,
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
export class NativeReceiver implements ReceiverPort {
  private readonly pipe: NativePipe<
    Snapshot,
    Snapshot | { snapshot: Snapshot; savedBinding: SavedRuntimeBinding | null }
  >;
  get child() {
    return this.pipe.child;
  }
  get ready() {
    return this.pipe.ready;
  }
  constructor(executable: string, directory: string, recordingLog: string) {
    this.pipe = new NativePipe(
      executable,
      ["run", directory, recordingLog],
      {
        ready(value, pid) {
          exact(value, ["version", "ready", "pid", "snapshot"]);
          if (value.version !== 1 || value.ready !== true || value.pid !== pid)
            throw new Error("invalid_ready");
          return decodeSnapshot(value.snapshot);
        },
        reply(value) {
          if (Object.hasOwn(value, "savedBinding")) {
            exact(value, [
              "version",
              "requestId",
              "ok",
              "snapshot",
              "savedBinding",
            ]);
            const snapshot = decodeSnapshot(value.snapshot);
            return {
              snapshot,
              savedBinding: decodeSavedBinding(value.savedBinding, snapshot),
            };
          }
          exact(value, ["version", "requestId", "ok", "snapshot"]);
          return decodeSnapshot(value.snapshot);
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
    return reply;
  }
  disconnect(): void {
    this.pipe.disconnect();
  }
}
