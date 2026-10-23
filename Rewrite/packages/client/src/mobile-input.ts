import { decodeGamepadState } from "@thumble/contracts";
import { counter, exact, record } from "@thumble/contracts/receiver";
import {
  decodeControlMap,
  RELEASE_REASONS,
  type ActivationReceipt,
  type NativeInputModule,
  type NativeInputSnapshot,
  type ReleaseReason,
} from "@thumble/contracts/mobile-input";

/** Bounded configuration bridge. It deliberately has no touch or per-frame sample method. */
export class MobileInputClient {
  constructor(private readonly native: NativeInputModule) {}
  async configure(value: unknown): Promise<ActivationReceipt> {
    const map = decodeControlMap(value);
    const receipt = record(await this.native.configure(map));
    exact(receipt, ["version", "generation", "revision"]);
    if (
      receipt.version !== 1 ||
      receipt.generation !== map.generation ||
      receipt.revision !== map.revision
    )
      throw new Error("native_activation_mismatch");
    return Object.freeze({
      version: 1,
      generation: map.generation,
      revision: map.revision,
    });
  }
  async setPractice(enabled: boolean): Promise<void> {
    if (typeof enabled !== "boolean") throw new Error("invalid_practice_mode");
    await this.native.setPractice(enabled);
  }
  async release(reason: ReleaseReason): Promise<void> {
    if (!RELEASE_REASONS.includes(reason))
      throw new Error("invalid_release_reason");
    await this.native.release(reason);
  }
  async snapshot(): Promise<NativeInputSnapshot> {
    const s = record(await this.native.snapshot());
    exact(s, ["generation", "connected", "practice", "state", "lastRelease"]);
    if (
      typeof s.connected !== "boolean" ||
      typeof s.practice !== "boolean" ||
      (s.lastRelease !== null &&
        !RELEASE_REASONS.includes(s.lastRelease as ReleaseReason))
    )
      throw new Error("invalid_native_snapshot");
    return Object.freeze({
      generation: counter(s.generation),
      connected: s.connected,
      practice: s.practice,
      state: decodeGamepadState(s.state),
      lastRelease: s.lastRelease as ReleaseReason | null,
    });
  }
}
