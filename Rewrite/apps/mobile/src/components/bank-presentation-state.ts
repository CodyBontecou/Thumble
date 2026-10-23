import type { BankPhonePresentationNotification } from "@thumble/contracts/phone-presentation";

type Bank = BankPhonePresentationNotification["bank"];
type Metadata = Extract<
  BankPhonePresentationNotification,
  { kind: "presentation" }
>;
export type BankVisuals = Readonly<{
  metadata: Metadata;
  icons: Readonly<Record<string, string>>;
  receivedAt: number;
  stale: boolean;
}>;
export type BankDisplay = Readonly<{
  visuals: BankVisuals | null;
  pending: boolean;
  stale: boolean;
}>;
const scopeFields = [
  "authorityInstanceId",
  "expectedConfigurationRevision",
  "expectedSourceHash",
  "profileId",
  "generation",
  "revision",
  "viewportWidth",
  "viewportHeight",
  "configurationSha256",
  "colorScheme",
] as const;
const uriPrefix = "data:image/png;base64,";

/** Cosmetic-only cache. A native semantic bank event selects what may be displayed. */
export class BankPresentationState {
  private scope: string | null = null;
  private selected: Bank | null = null;
  private readonly cache = new Map<Bank, BankVisuals>();
  private readonly failed = new Set<Bank>();
  private latest: { revision: string; hash: string } | null = null;
  constructor(private readonly controlIds: ReadonlySet<string>) {}

  private current(now: number): BankDisplay {
    const visual = this.selected ? this.cache.get(this.selected) : undefined;
    if (!visual)
      return {
        visuals: null,
        pending: this.selected !== null,
        stale: this.selected !== null && this.failed.has(this.selected),
      };
    const age = now - visual.receivedAt;
    const stale =
      visual.stale ||
      !Number.isFinite(age) ||
      age < 0 ||
      age >= 6000 ||
      (this.latest !== null &&
        (visual.metadata.presentationRevision !== this.latest.revision ||
          visual.metadata.presentationSourceHash !== this.latest.hash));
    return {
      visuals: stale ? { ...visual, stale: true } : visual,
      pending: false,
      stale,
    };
  }

  private trim() {
    const size = () => {
      let icons = 0,
        bytes = 0;
      for (const visual of this.cache.values())
        for (const uri of Object.values(visual.icons)) {
          icons++;
          const data = uri.slice(uriPrefix.length);
          bytes +=
            (data.length / 4) * 3 -
            (data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0);
        }
      return icons <= 64 && bytes <= 512 * 1024;
    };
    while (!size()) {
      const oldest = [...this.cache.keys()].find(
        (bank) => bank !== this.selected,
      );
      if (!oldest) break;
      this.cache.delete(oldest);
    }
  }

  accept(
    value: BankPhonePresentationNotification,
    now: number,
  ): BankDisplay | undefined {
    if (!Number.isFinite(now) || now < 0) return undefined;
    const scope = JSON.stringify(scopeFields.map((key) => value[key]));
    if (this.scope !== null && this.scope !== scope) return undefined;
    if (value.kind === "bank") {
      this.scope = scope;
      this.selected = value.bank;
      return this.current(now);
    }
    if (this.scope === null || this.selected === null) return undefined;
    const previous = this.cache.get(value.bank);
    if (value.kind === "error") {
      this.failed.add(value.bank);
      if (previous) this.cache.set(value.bank, { ...previous, stale: true });
      return this.current(now);
    }
    if (value.kind === "presentation") {
      if (
        value.controls.length !== this.controlIds.size ||
        value.controls.some((c) => !this.controlIds.has(c.id))
      )
        return undefined;
      if (
        this.latest &&
        (BigInt(value.presentationRevision) < BigInt(this.latest.revision) ||
          (value.presentationRevision === this.latest.revision &&
            value.presentationSourceHash !== this.latest.hash))
      )
        return undefined;
      this.failed.delete(value.bank);
      this.latest = {
        revision: value.presentationRevision,
        hash: value.presentationSourceHash,
      };
      const icons: Record<string, string> = Object.create(null);
      for (const control of value.controls) {
        const old = previous?.metadata.controls.find(
          (c) => c.id === control.id,
        );
        if (
          old?.iconSHA256 &&
          old.iconSHA256 === control.iconSHA256 &&
          previous?.icons[control.id]
        )
          icons[control.id] = previous.icons[control.id]!;
      }
      this.cache.delete(value.bank);
      this.cache.set(value.bank, {
        metadata: value,
        icons,
        receivedAt: now,
        stale: false,
      });
    } else {
      if (
        !previous ||
        value.presentationRevision !== previous.metadata.presentationRevision ||
        value.presentationSourceHash !==
          previous.metadata.presentationSourceHash ||
        !previous.metadata.controls.some(
          (c) => c.id === value.controlId && c.iconSHA256 === value.iconSHA256,
        )
      )
        return undefined;
      this.cache.set(value.bank, {
        ...previous,
        icons: {
          ...previous.icons,
          [value.controlId]: uriPrefix + value.pngBase64,
        },
      });
    }
    this.trim();
    return this.current(now);
  }
}
