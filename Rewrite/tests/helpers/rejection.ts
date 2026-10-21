import { expect } from "bun:test";

/** Bun 1.4.3 Windows can crash when .rejects.toThrow wraps socket rejections.
 * Capture the outcome first; retain assertions on both failure and exact code.
 * See docs/rewrite-evidence/m2/windows-runtime-diagnosis.md.
 */
export async function expectError(
  promise: Promise<unknown>,
  code: string,
): Promise<void> {
  const error: unknown = await promise.then(
    () => null,
    (failure: unknown) => failure,
  );
  expect(error).toBeInstanceOf(Error);
  expect(error instanceof Error ? error.message : undefined).toBe(code);
}
