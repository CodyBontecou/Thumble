import { NativePipe } from "./native-pipe.ts";
import { exact } from "@thumble/contracts/receiver";
import {
  decodeWowCaptureCommand,
  decodeWowCaptureControlStatus,
  type WowCaptureCommand,
  type WowCaptureControlStatus,
} from "@thumble/contracts/wow-capture-control";
/** Parent communicates only small metadata; never inflates PNGs or receives screen pixels. */
export class WowCaptureOwner {
  private readonly pipe: NativePipe<void, WowCaptureControlStatus>;
  constructor(helper: string, launcher: readonly string[]) {
    if (!launcher.length) throw new Error("wow_capture_launcher_invalid");
    this.pipe = new NativePipe(
      launcher[0]!,
      [
        ...launcher.slice(1),
        "__wow-capture",
        "run",
        "--capture-helper",
        helper,
      ],
      {
        ready(value, pid) {
          exact(value, ["version", "ready", "pid"]);
          if (
            value.version !== 1 ||
            value.ready !== "wow-capture" ||
            value.pid !== pid
          )
            throw new Error("wow_capture_ready_invalid");
        },
        reply(value) {
          exact(value, ["version", "requestId", "ok", "result"]);
          return decodeWowCaptureControlStatus(value.result);
        },
      },
      "wow_capture_owner_unavailable",
    );
  }
  get ready() {
    return this.pipe.ready;
  }
  get child() {
    return this.pipe.child;
  }
  request(command: WowCaptureCommand) {
    return this.pipe.request(decodeWowCaptureCommand(command));
  }
  disconnect() {
    this.pipe.disconnect();
  }
}
