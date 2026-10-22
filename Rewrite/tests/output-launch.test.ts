import { expect, test } from "bun:test";
import { outputLaunchOptions } from "../apps/cli/src/output-launch.ts";
test("physical output launch requires exact backend and explicit independent opt-in", () => {
  expect(outputLaunchOptions(new Map())).toEqual({ backend: "recording" });
  expect(
    outputLaunchOptions(
      new Map<string, string | true>([["--output", "recording"]]),
    ),
  ).toEqual({ backend: "recording" });
  expect(
    outputLaunchOptions(
      new Map<string, string | true>([
        ["--output", "macos-hid"],
        ["--allow-physical-output", true],
      ]),
    ),
  ).toEqual({ backend: "macos-hid", allowPhysicalOutput: true });
  for (const entries of [
    [["--output", "macos-hid"]],
    [["--allow-physical-output", true]],
    [["--output", "windows"]],
    [
      ["--output", "recording"],
      ["--allow-physical-output", true],
    ],
  ] as [string, string | true][][])
    expect(() => outputLaunchOptions(new Map(entries))).toThrow();
});
