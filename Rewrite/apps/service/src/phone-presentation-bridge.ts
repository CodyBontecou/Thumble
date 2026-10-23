import {
  decodePhonePresentationResult,
  type PhonePresentationEvent,
  type PhonePresentationCommand,
  type PhonePresentationResult,
  type PresentationError,
} from "@thumble/contracts/phone-presentation";
export type PhonePresentationOutcome =
  | { result: PhonePresentationResult }
  | { error: PresentationError };
/** One underlying owner read even after phone timeout; never queues input behind asset IO. */
export class PhonePresentationBridge {
  private pending = false;
  constructor(
    private readonly read: (
      command: PhonePresentationCommand,
    ) => Promise<unknown>,
  ) {}
  async execute(
    event: PhonePresentationEvent,
  ): Promise<PhonePresentationOutcome> {
    if (this.pending) return { error: "presentation_busy" };
    this.pending = true;
    const { version: _version, event: _event, eventId: _id, ...query } = event;
    const work = Promise.resolve()
      .then(() =>
        this.read({ command: "configuration-phone-presentation", ...query }),
      )
      .then(
        (value) =>
          ({
            result: decodePhonePresentationResult(value, query),
          }) as PhonePresentationOutcome,
        (error) =>
          ({
            error:
              error instanceof Error &&
              error.message === "configuration_owner_busy"
                ? "presentation_busy"
                : "presentation_unavailable",
          }) as PhonePresentationOutcome,
      )
      .catch(
        () =>
          ({ error: "presentation_unavailable" }) as PhonePresentationOutcome,
      )
      .finally(() => {
        this.pending = false;
      });
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        work,
        new Promise<PhonePresentationOutcome>((resolve) => {
          timer = setTimeout(
            () => resolve({ error: "presentation_timeout" }),
            2000,
          );
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  }
}
