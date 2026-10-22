import { expect, test } from "bun:test";
import { checkPortableSource } from "../tooling/check-boundaries.ts";
const file = "packages/domain/src/model.ts";

test("portable modules cannot import platform code, host policy or escape through relative paths", () => {
  for (const source of [
    'import fs from "node:fs";',
    'export * from "bun";',
    'import React from "react";',
    'import value from "@thumble/storage";',
    'import value from "./../../../../apps/service/index.ts";',
    'type File = import("node:fs").FileHandle;',
    'import value = require("node:fs");',
    'const value = await import("node:fs");',
    'const value = require("node:fs");',
  ])
    expect(() => checkPortableSource(file, source, "domain")).toThrow();
});

test("portable domain imports and ordinary document variables remain valid", () => {
  expect(() =>
    checkPortableSource(
      file,
      'import type { GamepadState } from "@thumble/contracts"; const document = {};',
      "domain",
    ),
  ).not.toThrow();
  expect(() =>
    checkPortableSource(file, 'export * from "./other.ts";', "domain"),
  ).not.toThrow();
  expect(() =>
    checkPortableSource(
      "packages/contracts/src/model.ts",
      'import { value } from "@thumble/domain";',
      "contracts",
    ),
  ).toThrow();
});

// The application may use pure domain operations, but domain/contracts cannot
// reverse that dependency or acquire storage/platform adapters.
test("application operations can depend on domain while reverse imports remain forbidden", () => {
  expect(() =>
    checkPortableSource(
      "packages/application/src/catalog.ts",
      'import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";',
      "application",
    ),
  ).not.toThrow();
  for (const name of ["domain", "contracts", "client"] as const)
    expect(() =>
      checkPortableSource(
        `packages/${name}/src/catalog.ts`,
        'import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";',
        name,
      ),
    ).toThrow();
});
