import { decodeConfigurationCommand } from "@thumble/contracts/configuration";

const help = {
  kind: "configuration-control-label-help",
  command: "configuration set-control-label",
  usage:
    "configuration set-control-label --operation-id ID --expected-revision REV --profile-id UUID --control-id UUID (--label TEXT | --clear-label) [--runtime-dir ABS] [--receiver ABS] [--json]",
  label:
    "Preserves exact Unicode up to 128 UTF-8 bytes. Use --label '' for an explicit blank or --label=TEXT for text starting with --.",
  clear:
    "--clear-label removes the customization override and restores the generated label.",
  retry:
    "Retry the same operation ID and exact intent to recover its durable receipt. A changed intent needs a new operation ID.",
  activation:
    "Edits saved appearance only. Does not activate, replace or retire input.",
} as const;

export function controlLabelHelp(values: readonly string[]) {
  if (!values.includes("--help")) return undefined;
  if (
    new Set(values).size !== values.length ||
    values.some((value) => !["--help", "--json"].includes(value))
  )
    throw new Error("invalid_configuration_option");
  return help;
}

export function controlLabelCommand(opts: ReadonlyMap<string, string | true>) {
  const allowed = new Set([
    "--runtime-dir",
    "--receiver",
    "--json",
    "--operation-id",
    "--expected-revision",
    "--profile-id",
    "--control-id",
    "--label",
    "--clear-label",
  ]);
  for (const key of opts.keys())
    if (!allowed.has(key)) throw new Error("invalid_configuration_option");
  if (opts.has("--label") === opts.has("--clear-label"))
    throw new Error("configuration_label_intent_required");
  function required(key: string): string {
    const value = opts.get(key);
    if (typeof value !== "string") throw new Error("missing_option");
    return value;
  }
  return decodeConfigurationCommand({
    command: "configuration-set-control-label",
    operationId: required("--operation-id"),
    expectedRevision: required("--expected-revision"),
    profileId: required("--profile-id"),
    controlId: required("--control-id"),
    label: opts.has("--clear-label") ? null : required("--label"),
  });
}
