import {
  decodeAnyPhonePresentationResult,
  type AnyPhonePresentationEvent,
  type AnyPhonePresentationCommand,
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
      command: AnyPhonePresentationCommand,
    ) => Promise<unknown>,
  ) {}
  async execute(
    event: AnyPhonePresentationEvent,
  ): Promise<PhonePresentationOutcome> {
    if (this.pending) return { error: "presentation_busy" };
    this.pending = true;
    const { version, event: _event, eventId: _id, ...fields } = event;
    const query =
      version === 2 ? { ...fields, presentationProtocol: 2 as const } : fields;
    const work = Promise.resolve()
      .then(() =>
        this.read({ command: "configuration-phone-presentation", ...query }),
      )
      .then(
        (value) =>
          ({
            result: decodeAnyPhonePresentationResult(value, query),
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
