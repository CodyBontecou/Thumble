// Test-only process owner. The two states model death before/after SQLite commit.
import { createHash } from "node:crypto";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { FileAssetStore } from "@thumble/storage/asset-files";
import { LosslessJson } from "@thumble/contracts/json";
const [root, executable, mode] = process.argv.slice(2);
if (
  !root ||
  !executable ||
  !["prepare-hold", "commit-hold"].includes(mode ?? "")
)
  throw new Error("test_arguments_invalid");
const bytes = new TextEncoder().encode("synthetic process asset"),
  sha = createHash("sha256").update(bytes).digest("hex");
const repository = new SqliteConfigurationRepository(root, executable),
  store = new FileAssetStore(root, executable);
const command = {
  operationId: "asset-operation",
  payloadHash: "a".repeat(64),
  expectedRevision: "0",
  source: LosslessJson.parse(JSON.stringify({ assetSHA256: sha })),
  affectedEntities: ["profile-a"],
  assets: [bytes],
};
const receipt =
  mode === "commit-hold" ? repository.commit(command).receipt : undefined;
// Recreate the same durable state as a crash after commit and before retirement.
const stage = store.prepare(command.operationId, command.payloadHash, [bytes]);
console.log(
  JSON.stringify({ ready: true, sha, stageId: stage.stageId, receipt }),
);
setTimeout(() => {
  repository.close();
  process.exit(1);
}, 20000);
