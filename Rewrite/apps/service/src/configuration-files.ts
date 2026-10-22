import { createHash } from "node:crypto";
import {
  validateOwnedConfiguration,
  type ConfigurationValidation,
} from "@thumble/application/configuration-validation";
import { readConfigurationFile } from "@thumble/client/local";
import { configurationSourceHash } from "@thumble/storage";
/** Explicit local-file inspection works without a running service or native receiver. */
export function inspectConfigurationFile(
  path: string,
): ConfigurationValidation {
  return validateOwnedConfiguration(readConfigurationFile(path), {
    resource: (bytes) => createHash("sha256").update(bytes).digest("hex"),
    source: configurationSourceHash,
  });
}
