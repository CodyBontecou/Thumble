import { expect, test } from "bun:test";
import {
  configurationControlLabel,
  decodeConfigurationControlLabelChange,
  decodeConfigurationSetControlLabelCommand,
} from "@thumble/contracts/control-label";
import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationSetControlLabelCommand,
} from "@thumble/contracts/configuration";
const profileId = "aaaaaaaa-0000-0000-0000-000000000001";
const controlId = "ce000000-0000-0000-0000-00000000000a";
const command: ConfigurationSetControlLabelCommand = {
  command: "configuration-set-control-label",
  operationId: "set-label-1",
  expectedRevision: "1",
  profileId,
  controlId,
  label: "Spell",
};

test("typed label command distinguishes exact Unicode, blank and clear, and normalizes UUIDs", () => {
  for (const label of [
    "Spell",
    "  Spell\n",
    "",
    null,
    "😀".repeat(32),
    "a".repeat(128),
  ]) {
    const decoded = decodeConfigurationCommand({
      ...command,
      profileId: profileId.toUpperCase(),
      controlId: controlId.toUpperCase(),
      label,
    });
    expect(decoded).toEqual({ ...command, label });
    expect(Object.isFrozen(decoded)).toBe(true);
  }
  expect(configurationControlLabel("\0")).toBe("\0");
  expect(
    decodeConfigurationControlLabelChange({ profileId, controlId, label: "" }),
  ).toEqual({ profileId, controlId, label: "" });
});
test("label UTF-8 and scalar boundaries reject oversized strings and lone surrogates", () => {
  for (const label of [
    "a".repeat(129),
    "😀".repeat(33),
    "é".repeat(65),
    "\ud800",
    "\udc00",
    undefined,
    1,
    {},
    [],
  ])
    expect(() => decodeConfigurationCommand({ ...command, label })).toThrow();
  expect(configurationControlLabel("é".repeat(64))).toBe("é".repeat(64));
});
test("command and targeted change reject missing, extra, inherited, accessor and symbol properties", () => {
  let reads = 0;
  const getter = { ...command };
  Object.defineProperty(getter, "label", {
    get() {
      reads++;
      return "bad";
    },
  });
  for (const bad of [
    getter,
    { ...command, extra: true },
    { ...command, [Symbol("extra")]: 1 },
    Object.create(command),
    { ...command, controlId: "not-uuid" },
    { ...command, profileId: "" },
    { ...command, operationId: "bad_id" },
    { ...command, expectedRevision: "01" },
    { ...command, expectedRevision: "18446744073709551616" },
    { ...command, command: "configuration-rename-profile" },
  ])
    expect(() => decodeConfigurationSetControlLabelCommand(bad)).toThrow();
  expect(reads).toBe(0);
  expect(() => decodeConfigurationControlLabelChange(command)).toThrow();
  const absent: Record<string, unknown> = { ...command };
  delete absent.label;
  expect(() => decodeConfigurationSetControlLabelCommand(absent)).toThrow();
});
test("existing receipt shape binds operation, next revision and profile/control affected entities", () => {
  const receipt = {
    version: 1,
    operationId: command.operationId,
    resultingRevision: "2",
    contentHash: "a".repeat(64),
    affectedEntities: [profileId, controlId],
  } as const;
  const reply = {
    version: 1,
    kind: "committed",
    receipt,
    replayed: false,
  } as const;
  expect(decodeConfigurationReply(reply, command)).toEqual(reply);
  expect(
    decodeConfigurationReply({ ...reply, replayed: true }, command),
  ).toEqual({ ...reply, replayed: true });
  for (const changed of [
    { ...receipt, affectedEntities: [controlId, profileId] },
    { ...receipt, affectedEntities: [profileId] },
    { ...receipt, operationId: "different" },
    { ...receipt, resultingRevision: "3" },
  ])
    expect(() =>
      decodeConfigurationReply({ ...reply, receipt: changed }, command),
    ).toThrow();
  expect(
    decodeConfigurationReply(
      { version: 1, kind: "conflict", currentRevision: "3" },
      command,
    ),
  ).toEqual({ version: 1, kind: "conflict", currentRevision: "3" });
});
