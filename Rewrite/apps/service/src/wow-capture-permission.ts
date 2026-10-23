import { exact, parseStrictJson, record } from "@thumble/contracts/receiver";
import {
  NativeWowCaptureProvider,
  type WowCaptureLauncher,
} from "./wow-capture-provider.ts";
/** Offline explicit inspection/request only. Never called by service status. */
export async function inspectWowCapturePermission(
  helper: string,
  request = false,
  launch?: WowCaptureLauncher,
): Promise<
  Readonly<{
    kind: "wow-capture-permission";
    status:
      | "authorized"
      | "permission-required"
      | "not-inspected"
      | "unavailable";
  }>
> {
  const provider = new NativeWowCaptureProvider(
    helper,
    request ? "--request-permission" : "--status",
    launch,
  );
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const text = await Promise.race([
      provider.permissionReply(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error("wow_capture_permission_timeout")),
          3000,
        );
      }),
    ]);
    const value = record(parseStrictJson(text));
    exact(value, ["version", "command", "status"]);
    if (
      value.version !== 1 ||
      value.command !==
        (request
          ? "wow-capture-permission-result"
          : "wow-capture-permission-status") ||
      (value.status !== "authorized" &&
        value.status !== "permission-required" &&
        value.status !== "not-inspected" &&
        value.status !== "unavailable")
    )
      throw new Error("wow_capture_permission_invalid");
    return { kind: "wow-capture-permission", status: value.status };
  } catch (error) {
    if (
      error instanceof Error &&
      [
        "wow_capture_permission_timeout",
        "wow_capture_provider_unavailable",
      ].includes(error.message)
    )
      throw error;
    throw new Error("wow_capture_permission_invalid");
  } finally {
    if (timer) clearTimeout(timer);
    void provider.stop();
  }
}
