import { decodePhonePresentationEvent } from "@thumble/contracts/phone-presentation";
import { PhonePresentationBridge } from "./phone-presentation-bridge.ts";
import { decodePhoneControlsEvent } from "@thumble/contracts/phone-controls";
import { PhoneControlsBridge } from "./phone-controls-bridge.ts";
import { decodePhoneCatalogEvent } from "@thumble/contracts/phone-catalog";
import { PhoneCatalogBridge } from "./phone-catalog-bridge.ts";
import {
  decodePairingCommand,
  decodePairingReply,
  type PairingCommand,
  type PairingReply,
} from "@thumble/contracts/pairing";
import { exact } from "@thumble/contracts/receiver";
import { NativePipe } from "./native-pipe.ts";
export class NativePairingHost {
  private readonly pipe: NativePipe<
    void,
    | PairingReply
    | {
        kind:
          | "phone-catalog-enabled"
          | "phone-controls-enabled"
          | "phone-presentation-enabled";
      }
  >;
  get child() {
    return this.pipe.child;
  }
  readonly ready: Promise<void>;
  constructor(
    executable: string,
    directory: string,
    private readonly authority: string,
    identityDirectory?: string,
    catalog?: PhoneCatalogBridge,
    controls?: PhoneControlsBridge,
    presentation?: PhonePresentationBridge,
  ) {
    let lastEvent = 0n,
      lastControlsEvent = 0n,
      lastPresentationEvent = 0n;
    this.pipe = new NativePipe<
      void,
      | PairingReply
      | {
          kind:
            | "phone-catalog-enabled"
            | "phone-controls-enabled"
            | "phone-presentation-enabled";
        }
    >(
      executable,
      [
        "pairing-host",
        directory,
        authority,
        ...(identityDirectory ? [identityDirectory] : []),
      ],
      {
        ready(value, pid) {
          exact(value, ["version", "ready", "pid", "authorityInstanceId"]);
          if (
            value.version !== 1 ||
            value.ready !== true ||
            value.pid !== pid ||
            value.authorityInstanceId !== authority
          )
            throw new Error("invalid_pairing_ready");
        },
        event: (value) => {
          if (value.event === "phone-presentation") {
            if (!presentation)
              throw new Error("unexpected_phone_presentation_event");
            const event = decodePhonePresentationEvent(value, authority);
            if (BigInt(event.eventId) <= lastPresentationEvent)
              throw new Error("phone_presentation_event_replayed");
            lastPresentationEvent = BigInt(event.eventId);
            void presentation
              .execute(event)
              .then((outcome) => {
                this.pipe.writeEvent({
                  version: 1,
                  event: "phone-presentation-reply",
                  eventId: event.eventId,
                  authorityInstanceId: authority,
                  ...outcome,
                });
              })
              .catch(() => this.pipe.disconnect());
            return;
          }
          if (value.event === "phone-controls") {
            if (!controls) throw new Error("unexpected_phone_controls_event");
            const event = decodePhoneControlsEvent(value, authority);
            if (BigInt(event.eventId) <= lastControlsEvent)
              throw new Error("phone_controls_event_replayed");
            lastControlsEvent = BigInt(event.eventId);
            void controls
              .execute(event)
              .then((outcome) => {
                this.pipe.writeEvent({
                  version: 1,
                  event: "phone-controls-reply",
                  eventId: event.eventId,
                  authorityInstanceId: authority,
                  ...outcome,
                });
              })
              .catch(() => this.pipe.disconnect());
            return;
          }
          if (!catalog) throw new Error("unexpected_phone_catalog_event");
          const event = decodePhoneCatalogEvent(value, authority);
          if (BigInt(event.eventId) <= lastEvent)
            throw new Error("phone_catalog_event_replayed");
          lastEvent = BigInt(event.eventId);
          void catalog
            .execute(event)
            .then((outcome) => {
              this.pipe.writeEvent({
                version: 1,
                event: "phone-catalog-reply",
                eventId: event.eventId,
                authorityInstanceId: authority,
                ...outcome,
              });
            })
            .catch(() => {
              this.pipe.disconnect();
            });
        },
        reply(value) {
          exact(value, ["version", "requestId", "ok", "result"]);
          if (
            catalog &&
            value.result &&
            typeof value.result === "object" &&
            "kind" in value.result &&
            value.result.kind === "phone-catalog-enabled"
          ) {
            exact(value.result as Record<string, unknown>, ["kind"]);
            return { kind: "phone-catalog-enabled" };
          }
          if (
            controls &&
            value.result &&
            typeof value.result === "object" &&
            "kind" in value.result &&
            value.result.kind === "phone-controls-enabled"
          ) {
            exact(value.result as Record<string, unknown>, ["kind"]);
            return { kind: "phone-controls-enabled" };
          }
          if (
            presentation &&
            value.result &&
            typeof value.result === "object" &&
            "kind" in value.result &&
            value.result.kind === "phone-presentation-enabled"
          ) {
            exact(value.result as Record<string, unknown>, ["kind"]);
            return { kind: "phone-presentation-enabled" };
          }
          const reply = decodePairingReply(value.result);
          if (reply.authorityInstanceId !== authority)
            throw new Error("pairing_authority_mismatch");
          return reply;
        },
      },
      "pairing_host_unavailable",
    );
    this.ready = this.pipe.ready.then(async () => {
      if (catalog) {
        const reply = await this.pipe.request({
          command: "phone-catalog-enable",
        });
        if (!("kind" in reply) || reply.kind !== "phone-catalog-enabled") {
          this.pipe.disconnect();
          throw new Error("phone_catalog_enable_invalid");
        }
      }
      if (controls) {
        const reply = await this.pipe.request({
          command: "phone-controls-enable",
        });
        if (!("kind" in reply) || reply.kind !== "phone-controls-enabled") {
          this.pipe.disconnect();
          throw new Error("phone_controls_enable_invalid");
        }
      }
      if (presentation) {
        const reply = await this.pipe.request({
          command: "phone-presentation-enable",
        });
        if (!("kind" in reply) || reply.kind !== "phone-presentation-enabled") {
          this.pipe.disconnect();
          throw new Error("phone_presentation_enable_invalid");
        }
      }
    });
  }
  async request(command: PairingCommand): Promise<PairingReply> {
    await this.ready;
    const reply = await this.pipe.request(decodePairingCommand(command));
    if ("kind" in reply) {
      this.pipe.disconnect();
      throw new Error("invalid_pairing_response");
    }
    return reply;
  }
  disconnect(): void {
    this.pipe.disconnect();
  }
}
