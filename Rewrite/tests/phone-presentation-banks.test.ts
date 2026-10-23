import { expect, test } from "bun:test";
import fixture from "../packages/fixtures/saved-controller-presentation-control-v11.json";
import {
  decodeBankPhonePresentationQuery,
  decodeAnyPhonePresentationCommand,
  decodeAnyPhonePresentationEvent,
  decodeAnyPhonePresentationResult,
  decodeBankPhonePresentationNotification,
  decodePhonePresentationQuery,
  decodePhonePresentationEvent,
  decodePhonePresentationResult,
  decodePhonePresentationNotification,
  presentationIconBytes,
  PRESENTATION_BANKS,
} from "@thumble/contracts/phone-presentation";
function query(f = fixture.variants[0]!, icon = false) {
  const {
    version: _,
    command: _c,
    connectionId: _i,
    ...q
  } = icon ? f.iconRequest : f.request;
  return {
    ...q,
    authorityInstanceId: "synthetic-authority",
    presentationProtocol: 2,
    kind: icon ? "icon" : "metadata",
  };
}
function result(f = fixture.variants[0]!, icon = false) {
  const {
    version: _,
    command: _c,
    connectionId: _i,
    ...v
  } = icon ? f.iconReply : f.reply;
  return v;
}
test("role11 shared golden covers exact four banks and both themes without weakening role10", () => {
  const shas = new Set<string>();
  for (const f of fixture.variants)
    for (const icon of [false, true]) {
      const q = decodeBankPhonePresentationQuery(query(f, icon));
      expect(
        decodeAnyPhonePresentationCommand({
          ...q,
          command: "configuration-phone-presentation",
        }),
      ).toEqual({ ...q, command: "configuration-phone-presentation" });
      const { presentationProtocol: _, ...wire } = q;
      expect(
        decodeAnyPhonePresentationEvent(
          { ...wire, version: 2, event: "phone-presentation", eventId: "1" },
          "synthetic-authority",
        ).version,
      ).toBe(2);
      expect(decodeAnyPhonePresentationResult(result(f, icon), q).kind).toBe(
        icon ? "icon" : "presentation",
      );
      expect(() => decodePhonePresentationQuery(q)).toThrow();
      expect(() =>
        decodePhonePresentationEvent(
          { ...wire, version: 2, event: "phone-presentation", eventId: "1" },
          "synthetic-authority",
        ),
      ).toThrow();
      if (icon) {
        shas.add(f.iconReply.iconSHA256);
        expect(presentationIconBytes(f.iconReply.pngBase64).length).toBe(
          f.iconReply.byteCount,
        );
      }
    }
  expect(shas.size).toBe(8);
  expect(fixture.semanticTriggerBoundaries.map((x) => x.bank)).toEqual([
    ...PRESENTATION_BANKS,
  ]);
});
test("v2 rejects wrong discriminator, implicit bank, cross-bank/theme icon replay and extra secret fields", () => {
  for (const delta of [
    { presentationProtocol: 1 },
    { presentationProtocol: "2" },
    { bank: undefined },
    { bank: "lt" },
    { bank: "Base" },
    { bank: "base " },
    { credential: "secret" },
  ])
    expect(() =>
      decodeBankPhonePresentationQuery({ ...query(), ...delta }),
    ).toThrow();
  const q = decodeBankPhonePresentationQuery(query());
  for (const delta of [
    { bank: "left-trigger" },
    { colorScheme: "dark" },
    { presentationProtocol: 2 },
    { rawSource: "private" },
  ])
    expect(() =>
      decodeAnyPhonePresentationResult({ ...result(), ...delta }, q),
    ).toThrow();
  const { presentationProtocol: _, ...oldQ } = q;
  expect(() =>
    decodePhonePresentationResult({ ...result(), bank: "left-trigger" }, oldQ),
  ).toThrow();
  expect(() =>
    decodeAnyPhonePresentationEvent(
      {
        ...oldQ,
        version: 2,
        event: "phone-presentation",
        eventId: "1",
        presentationProtocol: 2,
      },
      "synthetic-authority",
    ),
  ).toThrow();
});
test("native v2 notifications require the complete installed pin even for bank/error", () => {
  const q = decodeBankPhonePresentationQuery(query()),
    { kind: _, ...common } = q;
  for (const bank of PRESENTATION_BANKS) {
    const event = { ...common, kind: "bank" as const, bank };
    expect(decodeBankPhonePresentationNotification(event)).toEqual(event);
    expect(() => decodePhonePresentationNotification(event)).toThrow();
  }
  for (const key of Object.keys(common)) {
    const bad: Record<string, unknown> = { ...common, kind: "bank" };
    delete bad[key];
    expect(() => decodeBankPhonePresentationNotification(bad)).toThrow();
  }
  for (const delta of [
    { presentationRevision: "4" },
    { controlId: "secret" },
    { bank: "unknown" },
    { viewportWidth: "874px" },
    { expectedSourceHash: "A".repeat(64) },
    { generation: "0" },
  ])
    expect(() =>
      decodeBankPhonePresentationNotification({
        ...common,
        kind: "bank",
        ...delta,
      }),
    ).toThrow();
  expect(
    decodeBankPhonePresentationNotification({
      ...common,
      kind: "error",
      error: "presentation_stale",
    }).kind,
  ).toBe("error");
  expect(() =>
    decodeBankPhonePresentationNotification({
      ...common,
      kind: "error",
      error: "arbitrary error",
    }),
  ).toThrow();
});
test("v2 native metadata freezes dense controls and scopes icons to the requested bank and theme", () => {
  for (const f of fixture.variants) {
    const q = decodeBankPhonePresentationQuery(query(f)),
      { kind: _, ...common } = q;
    const metadata = decodeBankPhonePresentationNotification({
      ...common,
      kind: "presentation",
      presentationRevision: "4",
      presentationSourceHash: f.reply.presentationSourceHash,
      profileName: f.reply.profileName,
      freshness: "observed",
      controls: [
        {
          id: f.reply.control0Id,
          label: f.reply.control0Label,
          iconSHA256: f.iconReply.iconSHA256,
          iconByteCount: f.iconReply.byteCount,
          iconName: f.reply.control0IconName,
        },
      ],
    });
    expect(Object.isFrozen(metadata)).toBe(true);
    if (metadata.kind !== "presentation") throw Error("fixture");
    expect(Object.isFrozen(metadata.controls[0])).toBe(true);
    expect(
      decodeBankPhonePresentationNotification({
        ...common,
        kind: "icon",
        presentationRevision: "4",
        presentationSourceHash: f.reply.presentationSourceHash,
        controlId: f.iconReply.controlId,
        iconSHA256: f.iconReply.iconSHA256,
        pngBase64: f.iconReply.pngBase64,
      }).kind,
    ).toBe("icon");
    const sparse: unknown[] = [];
    sparse.length = 1;
    expect(() =>
      decodeBankPhonePresentationNotification({
        ...metadata,
        controls: sparse,
      }),
    ).toThrow();
    let touched = false;
    const accessor = { ...common, kind: "bank" };
    Object.defineProperty(accessor, "bank", {
      enumerable: true,
      get() {
        touched = true;
        return "base";
      },
    });
    expect(() => decodeBankPhonePresentationNotification(accessor)).toThrow();
    expect(touched).toBe(false);
  }
});
