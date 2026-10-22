import {
  decodeSnapshot,
  exact,
  type ReceiverCommand,
  type Snapshot,
} from "@thumble/contracts/receiver";
import type { ReceiverPort } from "@thumble/application";
import { NativePipe } from "./native-pipe.ts";
export class NativeReceiver implements ReceiverPort {
  private readonly pipe: NativePipe<Snapshot, Snapshot>;
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
          exact(value, ["version", "requestId", "ok", "snapshot"]);
          return decodeSnapshot(value.snapshot);
        },
      },
      "receiver_unavailable",
    );
  }
  request(body: ReceiverCommand): Promise<Snapshot> {
    return this.pipe.request(body);
  }
  disconnect(): void {
    this.pipe.disconnect();
  }
}
