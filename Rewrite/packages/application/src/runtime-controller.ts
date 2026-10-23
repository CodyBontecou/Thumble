import type {
  SavedConfigurationPin,
  SavedRearmStatus,
  SavedReadyPolicyStatus,
  SavedActivateCommand,
} from "@thumble/contracts/saved-runtime";
import {
  counter,
  type LocalCommand,
  type ReceiverCommand,
  type Snapshot,
} from "@thumble/contracts/receiver";
export interface ReceiverPort {
  request(command: ReceiverCommand): Promise<Snapshot>;
}
export interface SavedReadyPolicy {
  readPin(pin: SavedConfigurationPin): Promise<SavedConfigurationPin>;
  rearmStatus(): Promise<SavedRearmStatus>;
}
/** Configuration operations own activation; the native receiver owns all input timing. */
export class RuntimeController {
  private policyToken = {};
  private disarm(
    reason:
      | "operator-release"
      | "unsaved-activation"
      | "explicit-activation-required",
  ) {
    this.policyToken = {};
    this.maintainedPin = undefined;
    this.rearmFault = true;
    this.policyStatus = { state: "waiting-for-explicit-activation", reason };
    return this.policyToken;
  }
  private maintainedPin: SavedConfigurationPin | undefined;
  private rearmAttempt: string | undefined;
  private rearmFault = false;
  private policyStatus: SavedReadyPolicyStatus = {
    state: "waiting-for-explicit-activation",
    reason: "explicit-activation-required",
  };
  readiness(): SavedReadyPolicyStatus {
    return this.readyPolicy
      ? Object.freeze({ ...this.policyStatus })
      : Object.freeze({ state: "disabled", reason: "policy-disabled" });
  }
  private sessionId: string | undefined;
  private tail: Promise<unknown> = Promise.resolve();
  constructor(
    private readonly receiver: ReceiverPort,
    private readonly nextIdentity: () => string,
    readonly leaseMs = 750,
    readonly inputTtlMs = 350,
    private readonly readyPolicy?: SavedReadyPolicy,
  ) {}
  activateSaved(
    command: SavedActivateCommand,
    pin: SavedConfigurationPin,
  ): Promise<Snapshot> {
    const token = this.disarm("explicit-activation-required");
    const operation = this.tail.then(async () => {
      const status = await this.receiver.request({ command: "status" });
      if (status.revision !== command.expectedReceiverRevision)
        throw new Error("revision_conflict");
      if (
        pin.configurationRevision !== command.expectedConfigurationRevision ||
        pin.sourceHash !== command.expectedSourceHash ||
        pin.profileId !== command.profileId
      )
        throw new Error("saved_configuration_pin_mismatch");
      const generation = counter((BigInt(status.generation) + 1n).toString()),
        revision = counter((BigInt(status.revision) + 1n).toString()),
        sessionId = this.nextIdentity();
      const activated = await this.receiver.request({
        command: "activateSaved",
        generation,
        revision,
        profileId: pin.profileId,
        sessionId,
        leaseMs: this.leaseMs,
        inputTtlMs: this.inputTtlMs,
        configurationRevision: pin.configurationRevision,
        sourceHash: pin.sourceHash,
      });
      this.sessionId = sessionId;
      if (this.readyPolicy && token === this.policyToken) {
        this.maintainedPin = pin;
        this.rearmAttempt = undefined;
        this.rearmFault = false;
        this.policyStatus = {
          state: "armed",
          reason: "explicit-saved-activation",
        };
      }
      return activated;
    });
    this.tail = operation.catch(() => {});
    return operation;
  }
  execute(command: LocalCommand): Promise<Snapshot> {
    if (command.command === "release" || command.command === "stop")
      this.disarm("operator-release");
    else if (command.command === "activate") this.disarm("unsaved-activation");
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
    if (status.backend !== "recording")
      throw new Error("recorded_input_requires_recording_backend");
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
  private async maintainReady(status: Snapshot): Promise<void> {
    const policy = this.readyPolicy,
      pin = this.maintainedPin,
      token = this.policyToken;
    if (!policy || !pin || this.rearmFault) return;
    if (status.lastReleaseReason !== "native_input_released") {
      this.rearmFault = true;
      this.policyStatus = { state: "latched", reason: "release-not-clean" };
      return;
    }
    const attempt = `${status.generation}:${status.revision}`;
    if (attempt === this.rearmAttempt) return;
    this.rearmAttempt = attempt;
    // Consume before any asynchronous work; failures require explicit local activation.
    this.rearmFault = true;
    this.policyStatus = { state: "rearming", reason: "clean-release" };
    try {
      let current: SavedConfigurationPin;
      try {
        current = await policy.readPin(pin);
      } catch {
        if (token !== this.policyToken) return;
        this.policyStatus = {
          state: "latched",
          reason: "catalog-recheck-failed",
        };
        return;
      }
      if (token !== this.policyToken) return;
      if (
        current.configurationRevision !== pin.configurationRevision ||
        current.sourceHash !== pin.sourceHash ||
        current.profileId !== pin.profileId
      ) {
        this.policyStatus = { state: "latched", reason: "binding-changed" };
        return;
      }
      const proof = await policy.rearmStatus(),
        released = proof.releasedBinding;
      if (token !== this.policyToken) return;
      if (!proof.cleanupReady) {
        this.policyStatus = {
          state: "latched",
          reason: "retirement-unconfirmed",
        };
        return;
      }
      if (
        !released ||
        proof.snapshot.active ||
        proof.snapshot.generation !== status.generation ||
        proof.snapshot.revision !== status.revision ||
        released.configurationRevision !== pin.configurationRevision ||
        released.sourceHash !== pin.sourceHash ||
        released.profileId !== pin.profileId ||
        released.generation !== status.generation ||
        released.revision !== status.revision
      ) {
        this.policyStatus = { state: "latched", reason: "binding-changed" };
        return;
      }
      const sessionId = this.nextIdentity();
      const activated = await this.receiver.request({
        command: "activateSaved",
        generation: counter((BigInt(status.generation) + 1n).toString()),
        revision: counter((BigInt(status.revision) + 1n).toString()),
        profileId: pin.profileId,
        sessionId,
        leaseMs: this.leaseMs,
        inputTtlMs: this.inputTtlMs,
        configurationRevision: pin.configurationRevision,
        sourceHash: pin.sourceHash,
      });
      if (
        !activated.active ||
        !activated.inputEnabled ||
        activated.backend !== "macos-hid" ||
        activated.profileId !== pin.profileId ||
        activated.generation !==
          counter((BigInt(status.generation) + 1n).toString()) ||
        activated.revision !==
          counter((BigInt(status.revision) + 1n).toString())
      ) {
        this.policyStatus = { state: "latched", reason: "activation-failed" };
        return;
      }
      if (token !== this.policyToken) return;
      this.sessionId = sessionId;
      this.rearmFault = false;
      this.policyStatus = { state: "armed", reason: "clean-release" };
    } catch {
      if (token !== this.policyToken) return;
      this.policyStatus = { state: "latched", reason: "activation-failed" };
    }
  }
  renew(): Promise<void> {
    const operation = this.tail.then(async () => {
      if (!this.sessionId && !this.maintainedPin) return;
      const status = await this.receiver.request({ command: "status" });
      if (!status.active) {
        this.sessionId = undefined;
        await this.maintainReady(status);
        return;
      }
      if (!this.sessionId) {
        this.rearmFault = true;
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
