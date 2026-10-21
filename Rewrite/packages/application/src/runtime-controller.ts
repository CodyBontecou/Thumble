import {
  counter,
  type LocalCommand,
  type ReceiverCommand,
  type Snapshot,
} from "@thumble/contracts/receiver";
export interface ReceiverPort {
  request(command: ReceiverCommand): Promise<Snapshot>;
}
/** Configuration operations own activation; the native receiver owns all input timing. */
export class RuntimeController {
  private sessionId: string | undefined;
  private tail: Promise<unknown> = Promise.resolve();
  constructor(
    private readonly receiver: ReceiverPort,
    private readonly nextIdentity: () => string,
    readonly leaseMs = 750,
    readonly inputTtlMs = 350,
  ) {}
  execute(command: LocalCommand): Promise<Snapshot> {
    const operation = this.tail.then(() => this.apply(command));
    this.tail = operation.catch(() => {});
    return operation;
  }
  private async apply(command: LocalCommand): Promise<Snapshot> {
    if (command.command === "status")
      return this.receiver.request({ command: "status" });
    if (command.command === "release" || command.command === "stop") {
      this.sessionId = undefined;
      return this.receiver.request({
        command: command.command === "stop" ? "shutdown" : "release",
      });
    }
    const status = await this.receiver.request({ command: "status" });
    if (command.command === "activate") {
      if (command.expectedRevision !== status.revision)
        throw new Error("revision_conflict");
      const generation = counter((BigInt(status.generation) + 1n).toString());
      const revision = counter((BigInt(status.revision) + 1n).toString());
      const sessionId = this.nextIdentity();
      const activated = await this.receiver.request({
        command: "activate",
        generation,
        revision,
        profileId: command.profileId,
        sessionId,
        leaseMs: this.leaseMs,
        inputTtlMs: this.inputTtlMs,
      });
      this.sessionId = sessionId;
      return activated;
    }
    if (
      command.expectedGeneration !== status.generation ||
      !status.active ||
      !this.sessionId
    )
      throw new Error("inactive_generation");
    return this.receiver.request({
      command: "sample",
      generation: status.generation,
      sessionId: this.sessionId,
      sequence: command.sequence,
      state: command.state,
    });
  }
  renew(): Promise<void> {
    const operation = this.tail.then(async () => {
      if (!this.sessionId) return;
      const status = await this.receiver.request({ command: "status" });
      if (!status.active) {
        this.sessionId = undefined;
        return;
      }
      await this.receiver.request({
        command: "renew",
        generation: status.generation,
        sessionId: this.sessionId,
      });
    });
    this.tail = operation.catch(() => {});
    return operation;
  }
}
