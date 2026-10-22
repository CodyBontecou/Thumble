import { configurationImportIntent } from "@thumble/application/configuration-import";
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
  private readonly imports = new Map<
    string,
    { fingerprint: string; reply: ConfigurationReply }
  >();
  private activeImport: string | undefined;
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
  async request(input: ConfigurationCommand): Promise<ConfigurationReply> {
    const command = decodeConfigurationCommand(input);
    if (command.command === "configuration-import-status") {
      const job = this.imports.get(command.operationId);
      if (!job) throw new Error("configuration_import_unknown");
      if (job.fingerprint !== configurationImportIntent(command))
        throw new Error("operation_id_reused");
      return decodeConfigurationReply(job.reply, command);
    }
    await this.ready;
    if (command.command === "configuration-import-file") {
      const fingerprint = configurationImportIntent(command);
      const previous = this.imports.get(command.operationId);
      if (previous && previous.fingerprint !== fingerprint)
        throw new Error("operation_id_reused");
      if (previous && previous.reply.kind !== "import-failed") {
        const reply =
          previous.reply.kind === "import-committed"
            ? { ...previous.reply, replayed: true }
            : previous.reply;
        return decodeConfigurationReply(reply, command);
      }
      if (this.activeImport !== undefined)
        throw new Error("configuration_owner_busy");
      if (this.imports.size >= 32 && !previous) {
        const oldest = this.imports.keys().next().value;
        if (oldest !== undefined) this.imports.delete(oldest);
      }
      const pending = Object.freeze({
        version: 1,
        kind: "import-pending",
        operationId: command.operationId,
      } as const);
      this.imports.set(command.operationId, { fingerprint, reply: pending });
      this.activeImport = command.operationId;
      // A slow child holds only this bounded background promise. Polling and the
      // parent's input heartbeat never wait for its synchronous file/fsync work.
      void this.pipe
        .request(command, 30000)
        .then((value) => {
          let reply: ConfigurationReply;
          try {
            reply = decodeConfigurationReply(value, command);
            if (reply.kind !== "import-committed" && reply.kind !== "conflict")
              throw new Error("configuration_response_invalid");
          } catch {
            throw new Error("configuration_response_invalid");
          }
          this.imports.set(command.operationId, { fingerprint, reply });
        })
        .catch((error) => {
          const code =
            error instanceof Error && /^[a-z_]{1,80}$/.test(error.message)
              ? error.message
              : "configuration_import_failed";
          this.imports.set(command.operationId, {
            fingerprint,
            reply: Object.freeze({
              version: 1,
              kind: "import-failed",
              operationId: command.operationId,
              error: code,
            }),
          });
          if (
            code === "configuration_owner_unavailable" ||
            code === "configuration_response_invalid"
          ) {
            this.pipe.disconnect();
            this.child.kill("SIGKILL");
          }
        })
        .finally(() => {
          this.activeImport = undefined;
        });
      return pending;
    }
    if (this.activeImport !== undefined)
      throw new Error("configuration_owner_busy");
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
