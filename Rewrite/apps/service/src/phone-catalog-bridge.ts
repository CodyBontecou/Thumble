import {
  phoneCatalogCommand,
  projectPhoneCatalog,
  type PhoneCatalogCommand,
  type PhoneCatalogEvent,
  type PhoneCatalogError,
  type PhoneCatalogResult,
} from "@thumble/contracts/phone-catalog";
export type PhoneCatalogOutcome =
  | { result: PhoneCatalogResult }
  | { error: PhoneCatalogError };
/** One underlying read, even after the phone deadline expires. Input IO never waits here. */
export class PhoneCatalogBridge {
  private pending = false;
  constructor(
    private readonly read: (command: PhoneCatalogCommand) => Promise<unknown>,
  ) {}
  async execute(event: PhoneCatalogEvent): Promise<PhoneCatalogOutcome> {
    if (this.pending) return { error: "phone_catalog_busy" };
    const command = phoneCatalogCommand(event);
    this.pending = true;
    const work = Promise.resolve()
      .then(() => this.read(command))
      .then(
        (value) =>
          ({
            result: projectPhoneCatalog(value, command),
          }) as PhoneCatalogOutcome,
        (error) =>
          ({
            error:
              error instanceof Error &&
              error.message === "configuration_owner_busy"
                ? "phone_catalog_busy"
                : "phone_catalog_unavailable",
          }) as PhoneCatalogOutcome,
      )
      .catch(
        () => ({ error: "phone_catalog_unavailable" }) as PhoneCatalogOutcome,
      )
      .finally(() => {
        this.pending = false;
      });
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        work,
        new Promise<PhoneCatalogOutcome>((resolve) => {
          timer = setTimeout(
            () => resolve({ error: "phone_catalog_timeout" }),
            2000,
          );
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  }
}
