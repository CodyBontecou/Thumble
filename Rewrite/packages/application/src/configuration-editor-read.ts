import {
  decodeEditorReadCommand,
  type EditorReadCommand,
  type EditorProfilePage,
} from "@thumble/contracts/editor-read";
import type { ConfigurationReceipt } from "@thumble/contracts/configuration";
import { projectOwnedEditorProfilePage } from "@thumble/domain/owned-editor-profile";
import type { ConfigurationAccess } from "./configuration-catalog.ts";
import {
  ConfigurationRevisionConflict,
  type ConfigurationRepository,
} from "./configuration-store.ts";
import { controlLabelFingerprint } from "./control-label-fingerprint.ts";

export type EditorReadReply =
  | EditorProfilePage
  | Readonly<{ version: 1; kind: "editor-label-pending"; operationId: string }>
  | Readonly<{
      version: 1;
      kind: "editor-label-receipt";
      receipt: ConfigurationReceipt;
    }>;
/** Internal application seam. No network role or local capability is granted by these DTOs. */
export class ConfigurationEditorReads {
  constructor(
    private readonly repository: ConfigurationRepository,
    private readonly digest: (payload: string) => string,
  ) {}
  execute(
    input: EditorReadCommand,
    access: ConfigurationAccess,
  ): EditorReadReply {
    const command = decodeEditorReadCommand(input);
    if (!access.read) throw new Error("configuration_access_denied");
    if (command.command === "editor-label-status") {
      // Never inspect today's source or execute the intent to answer a receipt query.
      const receipt = this.repository.receipt(
        command.intent.operationId,
        controlLabelFingerprint(command.intent, this.digest),
      );
      return receipt
        ? Object.freeze({ version: 1, kind: "editor-label-receipt", receipt })
        : Object.freeze({
            version: 1,
            kind: "editor-label-pending",
            operationId: command.intent.operationId,
          });
    }
    const current = this.repository.current();
    if (!current || current.revision !== command.expectedRevision)
      throw new ConfigurationRevisionConflict(current?.revision ?? "0");
    if (current.contentHash !== command.expectedSourceHash)
      throw new Error("configuration_source_changed");
    return projectOwnedEditorProfilePage(current.source, command);
  }
}
