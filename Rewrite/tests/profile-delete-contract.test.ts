import { expect, test } from "bun:test";
import {
  decodeConfigurationDeleteProfileCommand,
  decodeConfigurationProfileDeleteChange,
} from "@thumble/contracts/profile-delete";
import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationDeleteProfileCommand,
} from "@thumble/contracts/configuration";
const id = "aaaaaaaa-0000-0000-0000-000000000001",
  other = "bbbbbbbb-0000-0000-0000-000000000002";
const command: ConfigurationDeleteProfileCommand = {
  command: "configuration-delete-profile",
  operationId: "delete-1",
  expectedRevision: "1",
  profileId: id,
  activeProfileId: other,
  defaultProfileId: null,
};
test("delete intent requires explicit postselectors and normalizes UUIDs without implicit defaults", () => {
  for (const defaultProfileId of [null, other]) {
    const decoded = decodeConfigurationCommand({
      ...command,
      profileId: id.toUpperCase(),
      activeProfileId: other.toUpperCase(),
      defaultProfileId: defaultProfileId?.toUpperCase() ?? null,
    });
    expect(decoded).toEqual({ ...command, defaultProfileId });
    expect(Object.isFrozen(decoded)).toBe(true);
  }
  expect(
    decodeConfigurationProfileDeleteChange({
      profileId: id,
      activeProfileId: other,
      defaultProfileId: null,
    }),
  ).toEqual({ profileId: id, activeProfileId: other, defaultProfileId: null });
});
test("strict deletion boundary rejects missing, extra, accessor, inherited and noncanonical intent", () => {
  let reads = 0;
  const getter = { ...command };
  Object.defineProperty(getter, "activeProfileId", {
    get() {
      reads++;
      return other;
    },
  });
  for (const bad of [
    getter,
    Object.create(command),
    { ...command, [Symbol()]: 1 },
    { ...command, extra: 1 },
    { ...command, operationId: "bad_id" },
    { ...command, expectedRevision: "01" },
    { ...command, expectedRevision: "18446744073709551616" },
    { ...command, profileId: "" },
    { ...command, activeProfileId: undefined },
    { ...command, defaultProfileId: "none" },
    { ...command, defaultProfileId: undefined },
    { ...command, command: "configuration-select-profiles" },
  ])
    expect(() => decodeConfigurationDeleteProfileCommand(bad)).toThrow();
  for (const key of Object.keys(command)) {
    const absent: Record<string, unknown> = { ...command };
    delete absent[key];
    expect(() => decodeConfigurationCommand(absent)).toThrow();
  }
  expect(reads).toBe(0);
  expect(() => decodeConfigurationProfileDeleteChange(command)).toThrow();
});
test("delete receipts bind deleted identity, operation and exactly next revision including replay", () => {
  const receipt = {
    version: 1,
    operationId: "delete-1",
    resultingRevision: "2",
    contentHash: "a".repeat(64),
    affectedEntities: ["configuration", id],
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
    { ...receipt, affectedEntities: [id, "configuration"] },
    { ...receipt, affectedEntities: ["configuration", other] },
    { ...receipt, operationId: "other" },
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
