import { configurationExportIntent } from "@thumble/application/configuration-export";
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
  private readonly jobs = new Map<
    string,
    { fingerprint: string; reply: ConfigurationReply }
  >();
  private activeJob: string | undefined;
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
    if (
      command.command === "configuration-import-status" ||
      command.command === "configuration-export-status"
    ) {
      const job = this.jobs.get(command.operationId);
      if (!job)
        throw new Error(
          command.command === "configuration-import-status"
            ? "configuration_import_unknown"
            : "configuration_export_unknown",
        );
      if (
        job.fingerprint !==
        (command.command === "configuration-import-status"
          ? configurationImportIntent(command)
          : configurationExportIntent(command))
      )
        throw new Error("operation_id_reused");
      return decodeConfigurationReply(job.reply, command);
    }
    await this.ready;
    if (
      command.command === "configuration-import-file" ||
      command.command === "configuration-export-file"
    ) {
      const importing = command.command === "configuration-import-file";
      const fingerprint =
        command.command === "configuration-import-file"
          ? configurationImportIntent(command)
          : configurationExportIntent(command);
      const previous = this.jobs.get(command.operationId);
      if (previous && previous.fingerprint !== fingerprint)
        throw new Error("operation_id_reused");
      if (
        previous &&
        previous.reply.kind !== "import-failed" &&
        previous.reply.kind !== "export-failed" &&
        previous.reply.kind !== "exported"
      ) {
        const reply =
          previous.reply.kind === "import-committed"
            ? { ...previous.reply, replayed: true }
            : previous.reply;
        return decodeConfigurationReply(reply, command);
      }
      if (this.activeJob !== undefined)
        throw new Error("configuration_owner_busy");
      if (this.jobs.size >= 32 && !previous) {
        const oldest = this.jobs.keys().next().value;
        if (oldest !== undefined) this.jobs.delete(oldest);
      }
      const pending = Object.freeze({
        version: 1,
        kind: importing ? "import-pending" : "export-pending",
        operationId: command.operationId,
      } as const);
      this.jobs.set(command.operationId, { fingerprint, reply: pending });
      this.activeJob = command.operationId;
      // A slow child holds only this bounded background promise. Polling and the
      // parent's input heartbeat never wait for its synchronous file/fsync work.
      void this.pipe
        .request(command, 30000)
        .then((value) => {
          let reply: ConfigurationReply;
          try {
            reply = decodeConfigurationReply(value, command);
            if (
              reply.kind !== (importing ? "import-committed" : "exported") &&
              reply.kind !== "conflict"
            )
              throw new Error("configuration_response_invalid");
          } catch {
            throw new Error("configuration_response_invalid");
          }
          this.jobs.set(command.operationId, { fingerprint, reply });
        })
        .catch((error) => {
          const code =
            error instanceof Error && /^[a-z_]{1,80}$/.test(error.message)
              ? error.message
              : importing
                ? "configuration_import_failed"
                : "configuration_export_failed";
          this.jobs.set(command.operationId, {
            fingerprint,
            reply: Object.freeze({
              version: 1,
              kind: importing ? "import-failed" : "export-failed",
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
          this.activeJob = undefined;
        });
      return pending;
    }
    if (this.activeJob !== undefined)
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
