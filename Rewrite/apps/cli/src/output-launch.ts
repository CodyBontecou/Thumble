import type { ReceiverOutput } from "@thumble/service/native-output-options";
/** Launch policy only; does not create a receiver or inspect/create any OS device. */
export function outputLaunchOptions(
  opts: ReadonlyMap<string, string | true>,
): ReceiverOutput {
  const backend = opts.get("--output") ?? "recording",
    allow = opts.get("--allow-physical-output") === true;
  if (backend === "recording") {
    if (allow) throw new Error("physical_output_option_mismatch");
    return { backend: "recording" };
  }
  if (backend !== "macos-hid") throw new Error("invalid_output_backend");
  if (!allow) throw new Error("physical_output_explicit_flag_required");
  return { backend: "macos-hid", allowPhysicalOutput: true };
}
