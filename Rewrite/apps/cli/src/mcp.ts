import { inspectConfigurationFile } from "@thumble/service/configuration-files";
import { decodeConfigurationCommand } from "@thumble/contracts/configuration";
import { McpServer, type CallToolResult } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import {
  readEndpointAsync,
  request,
  requestPairing,
  requestConfiguration,
} from "@thumble/client/local";
import { decodeLocalCommand } from "@thumble/contracts/receiver";
import { GAMEPAD_BUTTONS } from "@thumble/contracts";
import { z } from "zod";
import { BoundedStdioTransport } from "./mcp-transport.ts";

export function startMcp(
  root: string,
  receiver: string,
  allowRecordedInput: boolean,
  allowConfigurationWrite = false,
): void {
  let traces = 0;
  const trace = (phase: string): void => {
    if (process.env.THUMBLE_REWRITE_MCP_TRACE === "1" && traces++ < 128)
      console.error(`MCP transport phase=${phase}`);
  };
  const allowedTools = new Set([
    "receiver_status",
    "receiver_release",
    "pairing_status",
    "pairing_list",
    "configuration_list",
    "configuration_validate_file",
    ...(allowConfigurationWrite
      ? [
          "configuration_rename_profile",
          "configuration_import_file",
          "configuration_import_status",
          "configuration_export_file",
          "configuration_export_status",
        ]
      : []),
    ...(allowRecordedInput ? ["receiver_activate", "receiver_sample"] : []),
  ]);
  const transport = new BoundedStdioTransport(
    process.stdin,
    process.stdout,
    trace,
    allowedTools,
  );
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
      server.registerTool(
        "configuration_validate_file",
        {
          description:
            "Validate an explicit local owned-v5 configuration file without installation or migration. Returns bounded integrity/count metadata; platform output and image decoding remain separate activation gates.",
          inputSchema: z.object({ path: z.string().min(1).max(4096) }).strict(),
          annotations: annotations(true),
        },
        (args) => receipt(async () => inspectConfigurationFile(args.path)),
      );
      server.registerTool(
        "configuration_list",
        {
          description:
            "Read one bounded page of saved profile metadata. Catalog validation does not establish runtime validity. Pin expectedRevision when reading subsequent pages.",
          inputSchema: z
            .object({
              expectedRevision: epoch.nullable(),
              offset: z.number().int().min(0).max(255),
            })
            .strict(),
          annotations: annotations(true),
        },
        (args) =>
          receipt(async () =>
            requestConfiguration(
              await readEndpointAsync(root, receiver),
              decodeConfigurationCommand({
                command: "configuration-list",
                ...args,
              }),
            ),
          ),
      );
      if (allowConfigurationWrite)
        server.registerTool(
          "configuration_rename_profile",
          {
            description:
              "Rename the explicit saved profile at expectedRevision, preserving unrelated source. Retry with the same operationId and payload for the original durable receipt. Does not publish input configuration.",
            inputSchema: z
              .object({
                operationId: z.string().regex(/^[A-Za-z0-9-]{1,64}$/),
                expectedRevision: epoch,
                profileId: z
                  .string()
                  .regex(
                    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
                  ),
                name: z.string().min(1).max(512),
              })
              .strict(),
            annotations: annotations(false),
          },
          (args) =>
            receipt(async () =>
              requestConfiguration(
                await readEndpointAsync(root, receiver),
                decodeConfigurationCommand({
                  command: "configuration-rename-profile",
                  ...args,
                }),
              ),
            ),
        );
      if (allowConfigurationWrite) {
        for (const action of ["file", "status"] as const)
          server.registerTool(
            `configuration_import_${action}`,
            {
              description:
                action === "file"
                  ? "Start an explicit replacement of the entire saved configuration from a reviewed local owned-v5 file. expectedSourceHash is returned by configuration_validate_file. Returns a bounded pending job immediately; poll configuration_import_status with the same intent. Structural storage admission only; image/value/platform/activation gates remain separate. Retry the same intent to recover its durable receipt after restart."
                  : "Inspect a bounded import job using its exact operation ID, expected revision and reviewed source hash. Status never returns source, paths, assets or credentials. If the service restarted or its bounded cache retired the result, resubmit the original import intent for durable receipt recovery.",
              inputSchema: z
                .object({
                  operationId: z.string().regex(/^[A-Za-z0-9-]{1,64}$/),
                  expectedRevision: epoch,
                  expectedSourceHash: z.string().regex(/^[0-9a-f]{64}$/),
                  ...(action === "file"
                    ? { path: z.string().min(1).max(4096) }
                    : {}),
                })
                .strict(),
              annotations: annotations(action === "status"),
            },
            (args) =>
              receipt(async () =>
                requestConfiguration(
                  await readEndpointAsync(root, receiver),
                  decodeConfigurationCommand({
                    command:
                      action === "file"
                        ? "configuration-import-file"
                        : "configuration-import-status",
                    ...args,
                  }),
                ),
              ),
          );
      }
      if (allowConfigurationWrite) {
        for (const action of ["file", "status"] as const)
          server.registerTool(
            `configuration_export_${action}`,
            {
              description:
                action === "file"
                  ? "Export the entire saved configuration at the exact revision and content hash returned by configuration_list. Materializes verified resources into a standalone owned-v5 local file. Atomic no-clobber publication: an existing identical artifact is a replay; any other existing file is refused. Returns a background job immediately; poll configuration_export_status. No authority changes or activation. Export operation IDs are scoped to this service session; retry after restart requires the same current revision."
                  : "Inspect a bounded export job using the exact original operation ID, revision, authority content hash and destination path. The destination binds the intent but is never returned in status. Resubmit export-file if the service restarted; a changed authority returns conflict and existing output is untouched.",
              inputSchema: z
                .object({
                  operationId: z.string().regex(/^[A-Za-z0-9-]{1,64}$/),
                  expectedRevision: epoch,
                  expectedSourceHash: z.string().regex(/^[0-9a-f]{64}$/),
                  path: z.string().min(1).max(4096),
                })
                .strict(),
              annotations: annotations(action === "status"),
            },
            (args) =>
              receipt(async () =>
                requestConfiguration(
                  await readEndpointAsync(root, receiver),
                  decodeConfigurationCommand({
                    command:
                      action === "file"
                        ? "configuration-export-file"
                        : "configuration-export-status",
                    ...args,
                  }),
                ),
              ),
          );
      }
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
    { transport, maxSubscriptions: 0, onerror: () => trace("sdk-error") },
  );
}
