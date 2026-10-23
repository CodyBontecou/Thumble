import { expect, test } from "bun:test";
import { runCase } from "./harness.mjs";
test("isolated private stdio matcher once", async () => {
  const spec = JSON.parse(process.env.THUMBLE_STDIO_CASE);
  const result = await runCase(
    spec,
    spec.context === "bun-test-await"
      ? async (promise) => {
          // The hosted matcher rows are retained unchanged. This independent
          // control awaits native IO before invoking any synchronous matcher.
          const error = await promise.then(
            () => null,
            (failure) => failure,
          );
          expect(error).toBeInstanceOf(Error);
          expect(error instanceof Error ? error.message : undefined).toBe(
            "configuration_response_invalid",
          );
        }
      : (promise) =>
          expect(promise).rejects.toThrow("configuration_response_invalid"),
  );
  process.stdout.write("STDIO_RESULT " + JSON.stringify(result) + "\n");
  expect(result.passed).toBe(true);
}, 14000);
