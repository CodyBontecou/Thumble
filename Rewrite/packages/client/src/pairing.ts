import { identity } from "@thumble/contracts/receiver";
import {
  decodePairingCommand,
  decodePairingReply,
  type PairingCommand,
  type PairingReply,
} from "@thumble/contracts/pairing";
export interface PairingTransport {
  send(command: PairingCommand): Promise<unknown>;
}
export function decodePairingResponse(
  value: unknown,
  authorityInstanceId: string,
  command: PairingCommand,
): PairingReply {
  const reply = decodePairingReply(value);
  if (
    reply.authorityInstanceId !== authorityInstanceId ||
    (command.command === "pairing-open"
      ? reply.offer === null
      : reply.offer !== null)
  )
    throw new Error("pairing_authority_mismatch");
  return reply;
}
/** Configuration-only bridge. A native TLS adapter must authenticate the expected authority. */
export class PairingClient {
  constructor(
    private readonly authorityInstanceId: string,
    private readonly transport: PairingTransport,
  ) {
    identity(authorityInstanceId);
  }
  async request(command: PairingCommand): Promise<PairingReply> {
    const validated = decodePairingCommand(command);
    return decodePairingResponse(
      await this.transport.send(validated),
      this.authorityInstanceId,
      validated,
    );
  }
}
