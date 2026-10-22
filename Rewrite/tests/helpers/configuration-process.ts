// Test-only process owner; never bundled into the product.
import { SqliteConfigurationRepository } from "@thumble/storage";
import { LosslessJson } from "@thumble/contracts/json";
const [root, executable, mode] = process.argv.slice(2);
if (!root || !executable || !["hold", "commit-hold"].includes(mode ?? ""))
  throw new Error("test_arguments_invalid");
const repository = new SqliteConfigurationRepository(root, executable);
const result =
  mode === "commit-hold"
    ? repository.commit({
        operationId: "process-operation",
        payloadHash: "c".repeat(64),
        expectedRevision: "0",
        source: LosslessJson.parse('{"opaque":18446744073709551615}'),
        affectedEntities: ["profile-a"],
      })
    : undefined;
console.log(JSON.stringify({ ready: true, receipt: result?.receipt }));
setTimeout(() => {
  repository.close();
  process.exit(1);
}, 20000);
