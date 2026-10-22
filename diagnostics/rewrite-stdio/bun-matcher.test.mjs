import { expect, test } from "bun:test";
import { runCase } from "./harness.mjs";
test("isolated private stdio matcher once", async () => {
  const result = await runCase(
    JSON.parse(process.env.THUMBLE_STDIO_CASE),
    (promise) =>
      expect(promise).rejects.toThrow("configuration_response_invalid"),
  );
  process.stdout.write("STDIO_RESULT " + JSON.stringify(result) + "\n");
  expect(result.passed).toBe(true);
}, 14000);
