import { decodeSavedRuntimeCommand } from "@thumble/contracts/saved-runtime";
import { inspectOutputCapabilities } from "./output-doctor.ts";
import { inspectConfigurationFile } from "@thumble/service/configuration-files";
import { decodeConfigurationCommand } from "@thumble/contracts/configuration";
import { McpServer, type CallToolResult } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import {
  readEndpointAsync,
  request,
  requestPairing,
  requestConfiguration,
  requestSavedRuntime,
  requestSavedReadiness,
  requestWowCapture,
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
  allowWowCapture = false,
): void {
  let traces = 0;
  const trace = (phase: string): void => {
    if (process.env.THUMBLE_REWRITE_MCP_TRACE === "1" && traces++ < 128)
      console.error(`MCP transport phase=${phase}`);
  };
  const allowedTools = new Set([
    "output_doctor",
    "wow_capture_status",
    ...(allowWowCapture
      ? ["wow_capture_start", "wow_capture_request", "wow_capture_stop"]
      : []),
    "receiver_status",
    "receiver_saved_status",
    "receiver_readiness",
    "receiver_release",
    "pairing_status",
    "pairing_list",
    "configuration_list",
    "configuration_validate_file",
    ...(allowConfigurationWrite
      ? [
          "configuration_rename_profile",
          "configuration_select_profiles",
          "configuration_duplicate_profile",
          "configuration_initialize_starter",
          "configuration_import_file",
          "configuration_import_status",
          "configuration_export_file",
          "configuration_export_status",
        ]
      : []),
    ...(allowRecordedInput
      ? ["receiver_activate", "receiver_activate_saved", "receiver_sample"]
      : []),
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
        "wow_capture_status",
        {
          description:
            "Read optical capture metadata only. Does not start capture, inspect/request permission or advance game freshness.",
          inputSchema: empty,
          annotations: annotations(true),
        },
        () =>
          receipt(async () =>
            requestWowCapture(await readEndpointAsync(root, receiver), {
              command: "wow-capture-status",
            }),
          ),
      );
      if (allowWowCapture)
        for (const action of ["start", "request", "stop"] as const)
          server.registerTool(
            `wow_capture_${action}`,
            {
              description:
                "Explicit optical single-frame capture control. Requires a service launched with an authorized capture helper. No configuration commit or live-sync acceptance.",
              inputSchema: empty,
              annotations: { ...annotations(false), idempotentHint: false },
            },
            () =>
              receipt(async () =>
                requestWowCapture(
                  await readEndpointAsync(root, receiver),
                  action === "start"
                    ? {
                        command: "wow-capture-start",
                        source: "world-of-warcraft",
                      }
                    : {
                        command:
                          action === "request"
                            ? "wow-capture-request"
                            : "wow-capture-stop",
                      },
                ),
              ),
          );
      server.registerTool(
        "output_doctor",
        {
          description:
            "Inspect offline native output capabilities and signed-claim/source evidence without a running service. Recording-only; no device creation, driver probe, permission prompt or physical output.",
          inputSchema: empty,
          annotations: annotations(true),
        },
        () => receipt(() => inspectOutputCapabilities(receiver)),
      );
      server.registerTool(
        "receiver_readiness",
        {
          description:
            "Inspect the explicit local saved-controller maintenance policy and bounded latched reason; does not activate or renew input.",
          inputSchema: empty,
          annotations: annotations(true),
        },
        () =>
          receipt(async () =>
            requestSavedReadiness(await readEndpointAsync(root, receiver)),
          ),
      );
      server.registerTool(
        "receiver_saved_status",
        {
          description:
            "Inspect current native saved-source binding without activating or renewing input.",
          inputSchema: empty,
          annotations: annotations(true),
        },
        () =>
          receipt(async () =>
            requestSavedRuntime(await readEndpointAsync(root, receiver), {
              command: "saved-binding-status",
            }),
          ),
      );
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
      if (allowConfigurationWrite)
        server.registerTool(
          "configuration_initialize_starter",
          {
            description:
              "Initialize an EMPTY saved configuration authority with one production starter gamepad profile (14 buttons, two analog sticks, independent analog triggers). expectedRevision must be 0. Selects saved active/default only; never pairs, activates receiver input or creates OS devices. Refuses existing configuration; retry exact intent for original durable receipt.",
            inputSchema: z
              .object({
                operationId: z.string().regex(/^[A-Za-z0-9-]{1,64}$/),
                expectedRevision: z.literal("0"),
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
                  command: "configuration-initialize-starter",
                  ...args,
                }),
              ),
            ),
        );
      if (allowConfigurationWrite)
        server.registerTool(
          "configuration_duplicate_profile",
          {
            description:
              "Duplicate an explicit saved profile into a caller-selected fresh UUID/name at expectedRevision. Copies profile-scoped control IDs, opaque metadata, all saved states/resources and known profile binding maps. select is required: true selects the copy and synchronizes its saved binding mirrors atomically; false retains current selectors/root mirrors. Default remains unchanged. New name is trimmed. Retry the exact intent for the original durable receipt. No runtime publication or receiver input activation.",
            inputSchema: z
              .object({
                operationId: z.string().regex(/^[A-Za-z0-9-]{1,64}$/),
                expectedRevision: epoch,
                profileId: z
                  .string()
                  .regex(
                    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
                  ),
                newProfileId: z
                  .string()
                  .regex(
                    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
                  ),
                name: z.string().min(1).max(512),
                select: z.boolean(),
              })
              .strict(),
            annotations: annotations(false),
          },
          (args) =>
            receipt(async () =>
              requestConfiguration(
                await readEndpointAsync(root, receiver),
                decodeConfigurationCommand({
                  command: "configuration-duplicate-profile",
                  ...args,
                }),
              ),
            ),
        );
      if (allowConfigurationWrite)
        server.registerTool(
          "configuration_select_profiles",
          {
            description:
              "Atomically select explicit saved active/default profile IDs at expectedRevision and synchronize their saved active binding mirrors. Both profiles must exist; null clears the saved default. Existing selected per-profile maps win, including empty maps; absent entries use that profile's verified control defaults/configured outputs. Preserves profile contents/resources and unrelated maps, and commits a durable retry receipt even for unchanged selectors. Does not publish runtime configuration, enable receiver input, or establish activation compatibility.",
            inputSchema: z
              .object({
                operationId: z.string().regex(/^[A-Za-z0-9-]{1,64}$/),
                expectedRevision: epoch,
                activeProfileId: z
                  .string()
                  .regex(
                    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
                  ),
                defaultProfileId: z
                  .string()
                  .regex(
                    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
                  )
                  .nullable(),
              })
              .strict(),
            annotations: annotations(false),
          },
          (args) =>
            receipt(async () =>
              requestConfiguration(
                await readEndpointAsync(root, receiver),
                decodeConfigurationCommand({
                  command: "configuration-select-profiles",
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
          "receiver_activate_saved",
          {
            description:
              "Explicitly activate the selected saved snapshot in the recording receiver with independent source and native revision guards. No physical output.",
            inputSchema: z
              .object({
                expectedReceiverRevision: epoch,
                expectedConfigurationRevision: epoch,
                expectedSourceHash: z.string().regex(/^[0-9a-f]{64}$/),
                profileId: z.string().regex(/^[0-9a-f-]{36}$/i),
              })
              .strict(),
            annotations: { ...annotations(false), idempotentHint: false },
          },
          (args) =>
            receipt(async () =>
              requestSavedRuntime(
                await readEndpointAsync(root, receiver),
                decodeSavedRuntimeCommand({
                  command: "activate-saved",
                  ...args,
                }),
              ),
            ),
        );
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
