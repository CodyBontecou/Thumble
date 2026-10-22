import {
  decodePairingCommand,
  decodePairingReply,
  type PairingCommand,
  type PairingReply,
} from "@thumble/contracts/pairing";
import { exact } from "@thumble/contracts/receiver";
import { NativePipe } from "./native-pipe.ts";
export class NativePairingHost {
  private readonly pipe: NativePipe<void, PairingReply>;
  get child() {
    return this.pipe.child;
  }
  get ready() {
    return this.pipe.ready;
  }
  constructor(
    executable: string,
    directory: string,
    private readonly authority: string,
    identityDirectory?: string,
  ) {
    this.pipe = new NativePipe(
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
        reply(value) {
          exact(value, ["version", "requestId", "ok", "result"]);
          const reply = decodePairingReply(value.result);
          if (reply.authorityInstanceId !== authority)
            throw new Error("pairing_authority_mismatch");
          return reply;
        },
      },
      "pairing_host_unavailable",
    );
  }
  request(command: PairingCommand): Promise<PairingReply> {
    return this.pipe.request(decodePairingCommand(command));
  }
  disconnect(): void {
    this.pipe.disconnect();
  }
}
