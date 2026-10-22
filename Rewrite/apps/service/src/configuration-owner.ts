import { NativePipe } from "./native-pipe.ts";
import { exact } from "@thumble/contracts/receiver";
import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationCommand,
  type ConfigurationReply,
} from "@thumble/contracts/configuration";

/** Private child owner. Database decoding/fsync never runs on input heartbeat IO. */
export class ConfigurationOwner {
  private readonly pipe: NativePipe<void, unknown>;
  constructor(
    executable: string,
    directory: string,
    launcher: readonly string[],
  ) {
    if (launcher.length === 0)
      throw new Error("configuration_launcher_invalid");
    this.pipe = new NativePipe(
      launcher[0]!,
      [
        ...launcher.slice(1),
        "__configuration",
        "run",
        "--runtime-dir",
        directory,
        "--receiver",
        executable,
      ],
      {
        ready(value, pid) {
          exact(value, ["version", "ready", "pid"]);
          if (
            value.version !== 1 ||
            value.ready !== "configuration" ||
            value.pid !== pid
          )
            throw new Error("configuration_ready_invalid");
        },
        reply(value) {
          exact(value, ["version", "requestId", "ok", "result"]);
          return value.result;
        },
      },
      "configuration_owner_unavailable",
    );
  }
  get ready() {
    return this.pipe.ready;
  }
  get child() {
    return this.pipe.child;
  }
  // [DEBUG-config-pipe] Temporary native stdio evidence for the synthetic test.
  get diagnostics() {
    return this.pipe.diagnostics;
  }
  async request(input: ConfigurationCommand): Promise<ConfigurationReply> {
    const command = decodeConfigurationCommand(input);
    const value = await this.pipe.request(command);
    try {
      return decodeConfigurationReply(value, command);
    } catch {
      this.pipe.disconnect();
      throw new Error("configuration_response_invalid");
    }
  }
  disconnect(): void {
    this.pipe.disconnect();
  }
}
