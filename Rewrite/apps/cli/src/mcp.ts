import { McpServer, type CallToolResult } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import {
  readEndpointAsync,
  request,
  requestPairing,
} from "@thumble/client/local";
import { decodeLocalCommand } from "@thumble/contracts/receiver";
import { GAMEPAD_BUTTONS } from "@thumble/contracts";
import { z } from "zod";
import { BoundedStdioTransport } from "./mcp-transport.ts";

export function startMcp(
  root: string,
  receiver: string,
  allowRecordedInput: boolean,
): void {
  const transport = new BoundedStdioTransport(process.stdin, process.stdout);
  serveStdio(
    () => {
      const server = new McpServer({
        name: "thumble-rewrite",
        version: "0.0.0",
      });
      const empty = z.object({}).strict();
      const epoch = z
        .string()
        .regex(/^(?:0|[1-9][0-9]{0,19})$/)
        .refine((v) => BigInt(v) <= 18446744073709551615n);
      const receipt = async (
        operation: () => Promise<object>,
      ): Promise<CallToolResult> => {
        try {
          const result = await operation();
          return {
            content: [{ type: "text", text: JSON.stringify(result) }],
            structuredContent: { version: 1, ok: true, result },
          };
        } catch (error) {
          const code =
            error instanceof Error && /^[a-z_]{1,80}$/.test(error.message)
              ? error.message
              : "operation_failed";
          return {
            isError: true,
            content: [{ type: "text", text: code }],
            structuredContent: { version: 1, ok: false, error: code },
          };
        }
      };
      const annotations = (readOnlyHint: boolean) => ({
        readOnlyHint,
        destructiveHint: !readOnlyHint,
        idempotentHint: true,
        openWorldHint: false,
      });
      server.registerTool(
        "receiver_status",
        {
          description:
            "Inspect the running local service and recording receiver. No physical output is enabled.",
          inputSchema: empty,
          annotations: annotations(true),
        },
        () =>
          receipt(async () =>
            request(await readEndpointAsync(root, receiver), {
              command: "status",
            }),
          ),
      );
      server.registerTool(
        "receiver_release",
        {
          description:
            "Emergency neutralization of the current recording session. Always available.",
          inputSchema: empty,
          annotations: annotations(false),
        },
        () =>
          receipt(async () =>
            request(await readEndpointAsync(root, receiver), {
              command: "release",
            }),
          ),
      );
      for (const action of ["status", "list"] as const)
        server.registerTool(
          `pairing_${action}`,
          {
            description: `Inspect native phone pairing ${action}; no enrollment secrets are returned.`,
            inputSchema: empty,
            annotations: annotations(true),
          },
          () =>
            receipt(async () =>
              requestPairing(await readEndpointAsync(root, receiver), {
                command:
                  action === "status" ? "pairing-status" : "pairing-list",
              }),
            ),
        );
      // Capability comes only from the launching user's flag, never tool arguments.
      if (allowRecordedInput) {
        server.registerTool(
          "receiver_activate",
          {
            description:
              "Activate an ephemeral recording-only controller session at the expected revision.",
            inputSchema: z
              .object({
                expectedRevision: epoch,
                profileId: z.string().regex(/^[A-Za-z0-9-]{1,64}$/),
              })
              .strict(),
            annotations: { ...annotations(false), idempotentHint: false },
          },
          (args) =>
            receipt(async () =>
              request(
                await readEndpointAsync(root, receiver),
                decodeLocalCommand({ command: "activate", ...args }),
              ),
            ),
        );
        server.registerTool(
          "receiver_sample",
          {
            description:
              "Send a single bounded recording sample. No OS input is emitted.",
            inputSchema: z
              .object({
                expectedGeneration: epoch,
                sequence: epoch,
                state: z
                  .object({
                    buttons: z
                      .array(z.enum(GAMEPAD_BUTTONS))
                      .max(GAMEPAD_BUTTONS.length),
                    leftStickX: z.number().min(-1).max(1),
                    leftStickY: z.number().min(-1).max(1),
                    rightStickX: z.number().min(-1).max(1),
                    rightStickY: z.number().min(-1).max(1),
                    leftTrigger: z.number().min(0).max(1),
                    rightTrigger: z.number().min(0).max(1),
                  })
                  .strict(),
              })
              .strict(),
            annotations: { ...annotations(false), idempotentHint: false },
          },
          (args) =>
            receipt(async () =>
              request(
                await readEndpointAsync(root, receiver),
                decodeLocalCommand({
                  command: "sample",
                  ...args,
                  allowRecordedInput: true,
                }),
              ),
            ),
        );
      }
      return server;
    },
    { transport, maxSubscriptions: 0 },
  );
}
