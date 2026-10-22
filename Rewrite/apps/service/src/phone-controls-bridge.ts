import {
  decodePhoneControlsResult,
  type PhoneControlsEvent,
  type PhoneControlsCommand,
  type PhoneControlsResult,
  type SavedMapError,
} from "@thumble/contracts/phone-controls";
export type PhoneControlsOutcome =
  | { result: PhoneControlsResult }
  | { error: SavedMapError };
/** One underlying owner read even after phone timeout; never queues input behind asset IO. */
export class PhoneControlsBridge {
  private pending = false;
  constructor(
    private readonly read: (command: PhoneControlsCommand) => Promise<unknown>,
  ) {}
  async execute(event: PhoneControlsEvent): Promise<PhoneControlsOutcome> {
    if (this.pending) return { error: "saved_map_busy" };
    this.pending = true;
    const { version: _version, event: _event, eventId: _id, ...query } = event;
    const work = Promise.resolve()
      .then(() =>
        this.read({ command: "configuration-phone-controls", ...query }),
      )
      .then(
        (value) =>
          ({
            result: decodePhoneControlsResult(value, query),
          }) as PhoneControlsOutcome,
        (error) =>
          ({
            error:
              error instanceof Error &&
              error.message === "configuration_owner_busy"
                ? "saved_map_busy"
                : "saved_map_unavailable",
          }) as PhoneControlsOutcome,
      )
      .catch(() => ({ error: "saved_map_unavailable" }) as PhoneControlsOutcome)
      .finally(() => {
        this.pending = false;
      });
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        work,
        new Promise<PhoneControlsOutcome>((resolve) => {
          timer = setTimeout(
            () => resolve({ error: "saved_map_timeout" }),
            2000,
          );
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  }
}
