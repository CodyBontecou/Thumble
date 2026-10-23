import { decodeConfigurationCommand } from "@thumble/contracts/configuration";

const help = {
  kind: "configuration-delete-profile-help",
  command: "configuration delete-profile",
  usage:
    "configuration delete-profile --operation-id ID --expected-revision REV --profile-id UUID --active-profile-id UUID --default-profile-id none|UUID [--runtime-dir ABS] [--receiver ABS] [--json]",
  selection:
    "Both post-deletion selections are required. Choose a remaining active profile and either a remaining default profile or none. The last profile cannot be deleted.",
  retry:
    "Retry the same operation ID and exact intent to recover its durable receipt. A changed intent needs a new operation ID.",
  activation:
    "Changes saved configuration only. Does not replace or retire the installed input pin. Release and activate a saved profile separately when needed.",
} as const;

export function deleteProfileHelp(values: readonly string[]) {
  if (!values.includes("--help")) return undefined;
  if (
    new Set(values).size !== values.length ||
    values.some((value) => !["--help", "--json"].includes(value))
  )
    throw new Error("invalid_configuration_option");
  return help;
}

export function deleteProfileCommand(opts: ReadonlyMap<string, string | true>) {
  const allowed = new Set([
    "--runtime-dir",
    "--receiver",
    "--json",
    "--operation-id",
    "--expected-revision",
    "--profile-id",
    "--active-profile-id",
    "--default-profile-id",
  ]);
  for (const key of opts.keys())
    if (!allowed.has(key)) throw new Error("invalid_configuration_option");
  function required(key: string): string {
    const value = opts.get(key);
    if (typeof value !== "string") throw new Error("missing_option");
    return value;
  }
  const defaultId = required("--default-profile-id");
  return decodeConfigurationCommand({
    command: "configuration-delete-profile",
    operationId: required("--operation-id"),
    expectedRevision: required("--expected-revision"),
    profileId: required("--profile-id"),
    activeProfileId: required("--active-profile-id"),
    defaultProfileId: defaultId === "none" ? null : defaultId,
  });
}
