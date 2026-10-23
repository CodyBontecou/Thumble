import { expect, test } from "bun:test";
import fixture from "../packages/fixtures/saved-controller-presentation-control-v10.json";
import {
  decodePhonePresentationQuery,
  decodePhonePresentationCommand,
  decodePhonePresentationEvent,
  decodePhonePresentationResult,
  presentationIconBytes,
  PRESENTATION_ERRORS,
  decodePhonePresentationNotification,
} from "@thumble/contracts/phone-presentation";
const query = (icon = false): Record<string, unknown> => {
  const {
    version: _,
    command: _c,
    connectionId: _i,
    ...q
  } = icon ? fixture.iconRequest : fixture.request;
  return {
    ...q,
    authorityInstanceId: "synthetic-authority",
    kind: icon ? "icon" : "metadata",
  };
};
const result = (icon = false): Record<string, unknown> => {
  const {
    version: _,
    command: _c,
    connectionId: _i,
    ...r
  } = icon ? fixture.iconReply : fixture.reply;
  return { ...r };
};
test("presentation management shared fixture pins installed source separately from current presentation", () => {
  for (const icon of [false, true]) {
    const q = decodePhonePresentationQuery(query(icon));
    expect(
      decodePhonePresentationCommand({
        ...q,
        command: "configuration-phone-presentation",
      }).kind,
    ).toBe(q.kind);
    expect(
      decodePhonePresentationEvent(
        { ...q, event: "phone-presentation", version: 1, eventId: "1" },
        "synthetic-authority",
      ).eventId,
    ).toBe("1");
    expect(decodePhonePresentationResult(result(icon), q).kind).toBe(
      icon ? "icon" : "presentation",
    );
  }
  const q = decodePhonePresentationQuery(query());
  expect(fixture.errors).toEqual([...PRESENTATION_ERRORS]);
  for (const error of PRESENTATION_ERRORS)
    expect(decodePhonePresentationResult({ kind: "error", error }, q)).toEqual({
      kind: "error",
      error,
    });
  expect(presentationIconBytes(fixture.iconReply.pngBase64).length).toBe(
    fixture.iconReply.byteCount,
  );
});
test("strict presentation query rejects extras, noncanonical counters, unsupported theme/bank and unpinned icons", () => {
  for (const delta of [
    { kind: "other" },
    { expectedConfigurationRevision: "03" },
    { generation: "0" },
    { profileId: "not-a-profile" },
    { configurationSha256: "A".repeat(64) },
    { colorScheme: "system" },
    { bank: "lt" },
    { viewportWidth: "0" },
    { extra: 1 },
    { presentationRevision: null },
  ])
    expect(() =>
      decodePhonePresentationQuery({ ...query(), ...delta }),
    ).toThrow();
  for (const delta of [
    { presentationRevision: "2" },
    { presentationSourceHash: "x" },
    { controlId: "" },
    { iconSHA256: "x" },
  ])
    expect(() =>
      decodePhonePresentationQuery({ ...query(true), ...delta }),
    ).toThrow();
  expect(() =>
    decodePhonePresentationEvent(
      { ...query(), event: "phone-presentation", version: 1, eventId: "0" },
      "synthetic-authority",
    ),
  ).toThrow();
  expect(() =>
    decodePhonePresentationEvent(
      { ...query(), event: "phone-presentation", version: 1, eventId: "1" },
      "other-authority",
    ),
  ).toThrow();
});
test("presentation scalar projection rejects mismatches, structural fields, oversized UTF8 and partial icons", () => {
  const q = decodePhonePresentationQuery(query());
  for (const delta of [
    { kind: "icon" },
    { generation: "8" },
    { expectedSourceHash: "d".repeat(64) },
    { configurationSha256: "d".repeat(64) },
    { presentationRevision: "2" },
    { bank: "lt" },
    { freshness: "live" },
    { controlCount: 0 },
    { controlCount: 65 },
    { control1Id: fixture.reply.control0Id },
    { control0Label: "🙂".repeat(33) },
    { control0IconName: "é".repeat(65) },
    { control0Action: "south" },
    { source: "private-document" },
    { control0IconSHA256: null },
    { control0IconByteCount: 8193 },
  ])
    expect(() =>
      decodePhonePresentationResult({ ...result(), ...delta }, q),
    ).toThrow();
  const partial = result();
  delete partial.control0IconName;
  expect(() => decodePhonePresentationResult(partial, q)).toThrow();
  const empty = result();
  empty.control0Label = "";
  expect(decodePhonePresentationResult(empty, q).kind).toBe("presentation");
  for (const freshness of ["observed", "stale", "not-evaluated"])
    expect(
      decodePhonePresentationResult({ ...result(), freshness }, q).kind,
    ).toBe("presentation");
});
test("icon reads remain pinned and reject malformed/base64/oversized data without accepting a full atlas", () => {
  const q = decodePhonePresentationQuery(query(true));
  for (const delta of [
    { iconSHA256: "d".repeat(64) },
    { presentationRevision: "5" },
    { controlId: "other" },
    { byteCount: 1 },
    { pngBase64: "not-png" },
    { pngBase64: "A".repeat(10928) },
    { atlasPNGBase64: fixture.iconReply.pngBase64 },
  ])
    expect(() =>
      decodePhonePresentationResult({ ...result(true), ...delta }, q),
    ).toThrow();
  for (const text of ["", "AA=A", "A===", "a".repeat(10928)])
    expect(() => presentationIconBytes(text)).toThrow();
});

function notification(icon = false): Record<string, unknown> {
  const r = result(icon);
  const installed = Object.fromEntries(
    [
      "generation",
      "revision",
      "configurationSha256",
      "expectedConfigurationRevision",
      "expectedSourceHash",
      "profileId",
    ].map((k) => [k, r[k]]),
  );
  const presented = Object.fromEntries(
    ["presentationRevision", "presentationSourceHash", "colorScheme"].map(
      (k) => [k, r[k]],
    ),
  );
  return icon
    ? {
        kind: "icon",
        ...installed,
        ...presented,
        bank: "base",
        controlId: r.controlId,
        iconSHA256: r.iconSHA256,
        pngBase64: r.pngBase64,
      }
    : {
        kind: "presentation",
        ...installed,
        ...presented,
        bank: "base",
        profileName: r.profileName,
        freshness: r.freshness,
        controls: [
          {
            id: r.control0Id,
            label: r.control0Label,
            iconSHA256: r.control0IconSHA256,
            iconByteCount: r.control0IconByteCount,
            iconName: r.control0IconName,
          },
          { id: r.control1Id, label: r.control1Label },
        ],
      };
}
test("native presentation notifications keep metadata, small icons and errors separate and immutable", () => {
  const decoded = decodePhonePresentationNotification(notification());
  expect(decoded.kind).toBe("presentation");
  expect(Object.isFrozen(decoded)).toBe(true);
  if (decoded.kind === "presentation") {
    expect(decoded.controls).toHaveLength(2);
    expect(Object.isFrozen(decoded.controls)).toBe(true);
    expect(Object.isFrozen(decoded.controls[0])).toBe(true);
  }
  expect(decodePhonePresentationNotification(notification(true)).kind).toBe(
    "icon",
  );
  for (const error of PRESENTATION_ERRORS)
    expect(
      decodePhonePresentationNotification({
        kind: "error",
        error,
        generation: "7",
        revision: "2",
        configurationSha256: "b".repeat(64),
      }).kind,
    ).toBe("error");
});
test("hostile native notification objects cannot invoke getters or smuggle unknown input/source state", () => {
  let called = false;
  const getter = Object.defineProperty({ ...notification() }, "profileName", {
    enumerable: true,
    get() {
      called = true;
      return "private";
    },
  });
  expect(() => decodePhonePresentationNotification(getter)).toThrow();
  expect(called).toBe(false);
  const nested = notification();
  nested.controls = [
    Object.defineProperty({ id: "synthetic-south" }, "label", {
      enumerable: true,
      get() {
        called = true;
        return "private";
      },
    }),
  ];
  expect(() => decodePhonePresentationNotification(nested)).toThrow();
  expect(called).toBe(false);
  const array = notification();
  const controls: unknown[] = [];
  Object.defineProperty(controls, "0", {
    enumerable: true,
    get() {
      called = true;
      return { id: "synthetic-south", label: "" };
    },
  });
  array.controls = controls;
  expect(() => decodePhonePresentationNotification(array)).toThrow();
  expect(called).toBe(false);
  for (const value of [
    Object.assign(Object.create({ secret: true }), notification()),
    Object.defineProperty({ ...notification() }, "hidden", {
      value: "private",
    }),
    { ...notification(), [Symbol("secret")]: 1 },
  ])
    expect(() => decodePhonePresentationNotification(value)).toThrow();
  for (const extra of [
    { source: "document" },
    { credential: "bearer" },
    { controls: [] },
    { controls: Array(65).fill({ id: "x", label: "x" }) },
    {
      controls: [
        { id: "same", label: "" },
        { id: "same", label: "" },
      ],
    },
    { controls: [{ id: "x", label: "", iconSHA256: "a".repeat(64) }] },
    { controls: [{ id: "x", label: "🙂".repeat(33) }] },
    { controls: [{ id: "x", label: "", action: "south" }] },
    { bank: "lt" },
    { freshness: "authenticated" },
    { presentationRevision: "2" },
  ])
    expect(() =>
      decodePhonePresentationNotification({ ...notification(), ...extra }),
    ).toThrow();
  expect(() =>
    decodePhonePresentationNotification({
      ...notification(),
      pngBase64: fixture.iconReply.pngBase64,
    }),
  ).toThrow();
  expect(() =>
    decodePhonePresentationNotification({
      ...notification(true),
      controls: [],
    }),
  ).toThrow();
  expect(() =>
    decodePhonePresentationNotification({
      ...notification(true),
      pngBase64: "A".repeat(10928),
    }),
  ).toThrow();
  expect(() =>
    decodePhonePresentationNotification({
      kind: "error",
      error: "raw private failure",
      generation: "7",
      revision: "2",
      configurationSha256: "b".repeat(64),
    }),
  ).toThrow();
  expect(() =>
    decodePhonePresentationNotification({
      kind: "error",
      error: PRESENTATION_ERRORS[0],
      generation: "7",
      revision: "2",
      configurationSha256: "b".repeat(64),
      endpoint: "private",
    }),
  ).toThrow();
});
