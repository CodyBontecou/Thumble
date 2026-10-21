import { identity } from "@thumble/contracts/receiver";
import {
  PAIRING_ATTEMPTS,
  PAIRING_WINDOW_MS,
  pairingSecret,
  type PairingOffer,
  type PairingStatus,
} from "@thumble/contracts/pairing";

export interface PairingPorts {
  now(): number;
  nextIdentity(): string;
  randomSecret(): string;
  /** Domain-separated SHA-256 digest. Credentials are never retained in status. */
  digest(text: string): string;
  constantTimeEqual(a: string, b: string): boolean;
}
/** One native TLS admission opportunity. This does not persist trust or grant input. */
export class PairingWindows {
  private pending:
    | { id: string; verifier: string; expiresAt: number; attempts: number }
    | undefined;
  private lastTime = -1;
  constructor(
    readonly authorityInstanceId: string,
    private readonly ports: PairingPorts,
  ) {
    identity(authorityInstanceId);
  }
  private now(): number {
    const now = this.ports.now();
    if (
      !Number.isSafeInteger(now) ||
      now < this.lastTime ||
      now < 0 ||
      now > Number.MAX_SAFE_INTEGER - PAIRING_WINDOW_MS
    ) {
      this.pending = undefined;
      throw new Error("pairing_clock_invalid");
    }
    this.lastTime = now;
    if (this.pending && now >= this.pending.expiresAt) this.pending = undefined;
    return now;
  }
  private verifier(id: string, secret: string): string {
    return pairingSecret(
      this.ports.digest(
        `thumble-rewrite/pairing/v1\0${this.authorityInstanceId}\0${id}\0${secret}`,
      ),
    );
  }
  open(): PairingOffer {
    const now = this.now();
    // Invalidate old material even when entropy generation or hashing fails.
    this.pending = undefined;
    const id = identity(this.ports.nextIdentity());
    const secret = pairingSecret(this.ports.randomSecret());
    const verifier = this.verifier(id, secret);
    this.pending = {
      id,
      verifier,
      expiresAt: now + PAIRING_WINDOW_MS,
      attempts: PAIRING_ATTEMPTS,
    };
    return Object.freeze({
      windowId: id,
      secret,
      expiresAt: now + PAIRING_WINDOW_MS,
    });
  }
  status(): PairingStatus {
    this.now();
    const p = this.pending;
    return Object.freeze(
      p
        ? {
            state: "open",
            windowId: p.id,
            expiresAt: p.expiresAt,
            attemptsRemaining: p.attempts,
            networkEnabled: false,
          }
        : {
            state: "closed",
            windowId: null,
            expiresAt: null,
            attemptsRemaining: 0,
            networkEnabled: false,
          },
    );
  }
  cancel(): void {
    this.pending = undefined;
  }
  /** Only a pinned native TLS adapter may call this after host/phone identity validation. */
  admit(
    windowId: unknown,
    proof: unknown,
  ): Readonly<{ authorityInstanceId: string; windowId: string }> {
    this.now();
    const p = this.pending;
    if (!p) throw new Error("pairing_closed");
    p.attempts--;
    if (p.attempts === 0) this.pending = undefined;
    let accepted = false;
    try {
      const id = identity(windowId),
        secret = pairingSecret(proof);
      const candidate = this.verifier(id, secret);
      accepted =
        this.ports.constantTimeEqual(p.verifier, candidate) && id === p.id;
    } catch {
      /* Every failed proof spends the same window budget. */
    }
    if (!accepted) throw new Error("pairing_proof_rejected");
    this.pending = undefined;
    return Object.freeze({
      authorityInstanceId: this.authorityInstanceId,
      windowId: p.id,
    });
  }
}
