import { ConfigurationPhoneControlsOperations } from "@thumble/application/configuration-phone-controls";
import { ConfigurationPhonePresentationOperations } from "@thumble/application/configuration-phone-presentation";
import {
  PRESENTATION_BANKS,
  type PhonePresentationCommand,
} from "@thumble/contracts/phone-presentation";
import { verifyPresentationIcon } from "../apps/service/src/presentation-icon.ts";
import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { WowLiveObserver } from "@thumble/application/wow-live-observer";
import {
  WowProfileRefresh,
  WowRefreshObservation,
  WowRefreshCancellation,
} from "@thumble/application/wow-profile-refresh";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { projectSavedController } from "@thumble/domain/saved-controller-map";
import {
  SqliteConfigurationRepository,
  configurationSourceHash,
} from "@thumble/storage";
import { FileAssetStore } from "@thumble/storage/asset-files";
import {
  RetainedWowProfilePreparer,
  wowLiveProfileId,
} from "@thumble/service/wow-profile-preparer";
import { atlas, digest } from "./helpers/wow-refresh.ts";
import { WowCapturedFrame } from "@thumble/domain/wow-capture-receipt";
import { wowLiveChecksum } from "@thumble/domain/wow-live";
import { decodeWowAtlas } from "../apps/service/src/wow-atlas-decoder.ts";
const helper = process.env.THUMBLE_TEST_RETAINED_WOW_HELPER;
(helper ? test : test.skip)(
  "actual retained helper commits a multi-page icon snapshot to SQLite and projects all18 starter controls",
  async () => {
    const root = mkdtempSync(
      join(
        process.platform === "darwin" ? "/private/tmp" : tmpdir(),
        "thumble-retained-wow-",
      ),
    );
    const executable = resolve(
      import.meta.dir,
      "../native/receiver/target/debug/thumble-rewrite-receiver",
    );
    const repository = new SqliteConfigurationRepository(root, executable);
    try {
      const assets = new FileAssetStore(root, executable),
        observer = new WowLiveObserver();
      const fixture = JSON.parse(
        readFileSync(
          resolve(import.meta.dir, "../packages/fixtures/wow-live-v1.json"),
          "utf8",
        ),
      );
      const presentations = new ConfigurationPhonePresentationOperations(
        repository,
        {
          sourceHash: configurationSourceHash,
          documentHash: digest,
          resourceHash: digest,
          readAsset: (hash) => assets.read(hash),
          verifyIcon: verifyPresentationIcon,
          freshness: () => "not-evaluated",
        },
      );
      const controls = new ConfigurationPhoneControlsOperations(repository, {
        sourceHash: configurationSourceHash,
        documentHash: digest,
        resourceHash: digest,
        readAsset: (hash) => assets.read(hash),
        served: (query, hash, map) => presentations.remember(query, hash, map),
      });
      let oldPresentation: PhonePresentationCommand | undefined;
      let now = 100,
        receipt = 0,
        operation = 0;
      function observe(snapshot: unknown): WowRefreshObservation {
        const payload = Buffer.from(JSON.stringify(snapshot)),
          count = Math.ceil(payload.length / 487);
        for (let cycle = 0; cycle < 3; cycle++)
          for (let page = 0; page < count; page++) {
            const part = payload.subarray(page * 487, (page + 1) * 487),
              bytes = new Uint8Array(512),
              view = new DataView(bytes.buffer);
            bytes.set([84, 72, 87, 76, 1]);
            view.setUint32(5, ++receipt, true);
            view.setUint32(9, wowLiveChecksum(payload), true);
            view.setUint16(13, page, true);
            view.setUint16(15, count, true);
            view.setUint16(17, part.length, true);
            view.setUint16(19, payload.length, true);
            bytes.set(part, 25);
            const crcInput = new Uint8Array(21 + part.length);
            crcInput.set(bytes.subarray(0, 21));
            crcInput.set(part, 21);
            view.setUint32(21, wowLiveChecksum(crcInput), true);
            const frame = new WowCapturedFrame(
              {
                kind: "frame",
                source: 42,
                generation: "1",
                receipt: String(receipt),
                frame: bytes,
                atlasPNG: atlas(),
              },
              now,
              decodeWowAtlas,
            );
            const observation = WowRefreshObservation.observe(
              observer,
              frame,
              now++,
            );
            if (observation) return observation;
          }
        throw Error("fixture_observation_missing");
      }
      const refresh = new WowProfileRefresh(repository, {
        clock: () => now,
        currentCapture: () => true,
        readAsset: (h) => assets.read(h),
        resourceHash: digest,
        digest,
        sourceHash: configurationSourceHash,
        profileId: wowLiveProfileId,
        operationId: () => `retained-offline-proof-${++operation}`,
        preparer: new RetainedWowProfilePreparer(helper!),
      });
      const a = fixture.snapshot,
        b = JSON.parse(JSON.stringify(a));
      b.character.id = "Player-Other-Synthetic";
      b.character.name = "Other Synthetic";
      const changedA = JSON.parse(JSON.stringify(a));
      for (const action of changedA.actions) {
        if (action.iconFileID === 132282) {
          action.iconFileID = 132337;
          action.iconIndex = 2;
        } else if (action.iconFileID === 132337) {
          action.iconFileID = 132282;
          action.iconIndex = 1;
        }
      }
      let originalId = "";
      for (const snapshot of [a, b, changedA, a]) {
        const result = await refresh.execute(
          observe(snapshot),
          new WowRefreshCancellation().signal,
          () => true,
        );
        expect(result.kind).toBe("committed");
        if (result.kind !== "committed")
          throw Error("actual_retained_commit_failed");
        expect(result.acknowledged).toBe(true);
        originalId ||= result.profileID;
        const current = repository.current()!,
          document = OwnedAuthorityDocument.read(current.source).materialize(
            (h) => assets.read(h),
            digest,
          ),
          before = document.source.text();
        const projection = projectSavedController(
          { document, authorityRevision: current.revision },
          {
            profileId: result.profileID,
            authorityRevision: current.revision,
            sourceSha256: digest(before),
          },
          { generation: "1", revision: "1" },
          { width: 874, height: 393 },
          digest,
        );
        expect(projection.map.controls).toHaveLength(18);
        for (const action of [
          "leftStandardStick",
          "rightStandardStick",
          "leftVerticalTrigger",
          "rightVerticalTrigger",
        ] as const)
          expect(projection.map.controls.map((c) => c.action)).toContain(
            action,
          );
        const profileIndex = document.catalog.profiles.findIndex(
          (p) => p.id === result.profileID,
        );
        expect(
          document.source.get(`/profiles/${profileIndex}/appearanceResources`)!
            .keys.length,
        ).toBeGreaterThan(0);
        expect(
          document.source.get(
            `/profiles/${profileIndex}/appearanceBank/variants/0/appearance/controls/ce000000-0000-0000-0000-000000000008/icon/value`,
          )?.stringValue,
        ).toBe(
          snapshot === changedA
            ? "wow-live-icon-132337"
            : "wow-live-icon-132282",
        );
        expect(document.source.text()).toBe(before);
        if (operation === 1) {
          const query = {
            authorityInstanceId: "retained-authority",
            expectedConfigurationRevision: current.revision,
            expectedSourceHash: current.contentHash,
            profileId: result.profileID,
            generation: "7",
            revision: "2",
            viewportWidth: "874",
            viewportHeight: "393",
          };
          const served = controls.execute({
            command: "configuration-phone-controls",
            ...query,
          });
          if (served.kind !== "controls") throw Error("actual_map_missing");
          oldPresentation = {
            command: "configuration-phone-presentation",
            kind: "metadata",
            ...query,
            configurationSha256: String(served.configurationSha256),
            colorScheme: "light",
          };
        }
        const metadata = presentations.execute(oldPresentation!);
        if (snapshot === b)
          expect(metadata).toEqual({
            kind: "error",
            error: "presentation_reactivation_required",
          });
        else {
          expect(metadata.kind).toBe("presentation");
          if (metadata.kind !== "presentation")
            throw Error("actual_presentation_missing");
          expect(metadata.expectedConfigurationRevision).toBe("1");
          expect(metadata.presentationRevision).toBe(current.revision);
          expect(metadata.controlCount).toBe(18);
          const icon = presentations.execute({
            ...oldPresentation!,
            kind: "icon",
            presentationRevision: String(metadata.presentationRevision),
            presentationSourceHash: String(metadata.presentationSourceHash),
            controlId: "ce000000-0000-0000-0000-000000000008",
            iconSHA256: String(metadata.control7IconSHA256),
          });
          expect(icon.kind).toBe("icon");
          // The actual retained helper must serve every bank/theme from the old
          // installed input proof, including a base control with no icon.
          for (const colorScheme of ["light", "dark"] as const)
            for (const bank of PRESENTATION_BANKS) {
              const query = {
                ...oldPresentation!,
                presentationProtocol: 2 as const,
                bank,
                colorScheme,
              };
              const banked = presentations.execute(query);
              expect(banked.kind).toBe("presentation");
              if (banked.kind !== "presentation")
                throw Error("actual_banked_presentation_missing");
              expect(banked.bank).toBe(bank);
              expect(banked.colorScheme).toBe(colorScheme);
              expect(banked.controlCount).toBe(18);
              expect(banked.expectedConfigurationRevision).toBe("1");
              if (bank === "base")
                expect(banked.control9IconSHA256).toBeUndefined();
              else expect(banked.control9IconSHA256).toMatch(/^[a-f0-9]{64}$/);
              const requestedControl =
                bank === "base"
                  ? "ce000000-0000-0000-0000-000000000008"
                  : "ce000000-0000-0000-0000-00000000000a";
              const requestedSHA =
                bank === "base"
                  ? banked.control7IconSHA256
                  : banked.control9IconSHA256;
              const bytes = presentations.execute({
                ...query,
                kind: "icon",
                presentationRevision: String(banked.presentationRevision),
                presentationSourceHash: String(banked.presentationSourceHash),
                controlId: requestedControl,
                iconSHA256: String(requestedSHA),
              });
              expect(bytes.kind).toBe("icon");
              if (bytes.kind === "icon") expect(bytes.bank).toBe(bank);
            }
        }
        if (operation === 1) {
          const edited = current.source
            .set("/document/profiles/0/manualOpaque", '{"number":1e+03}')
            .set("/document/profiles/0/name", '"My retained name"');
          repository.commit({
            operationId: "manual-opaque-edit",
            payloadHash: configurationSourceHash(edited),
            expectedRevision: current.revision,
            source: edited,
            affectedEntities: ["configuration"],
          });
        } else {
          expect(document.source.get("/profiles/0/manualOpaque")?.text()).toBe(
            '{"number":1e+03}',
          );
          expect(document.source.get("/profiles/0/name")?.stringValue).toBe(
            "My retained name",
          );
        }
      }
      expect(repository.current()!.revision).toBe("5");
      const prior = repository.current()!,
        empty = prior.source
          .set("/document/profileOutputBindings/" + originalId, "{}")
          .set("/document/outputBindings", "{}");
      repository.commit({
        operationId: "manual-empty-bindings",
        payloadHash: configurationSourceHash(empty),
        expectedRevision: prior.revision,
        source: empty,
        affectedEntities: ["configuration"],
      });
      const final = await refresh.execute(
        observe(changedA),
        new WowRefreshCancellation().signal,
        () => true,
      );
      expect(final.kind).toBe("committed");
      const stored = repository.current()!,
        document = OwnedAuthorityDocument.read(stored.source).materialize(
          (h) => assets.read(h),
          digest,
        );
      expect(
        document.source.get("/profileOutputBindings/" + originalId)?.text(),
      ).toBe("{}");
      expect(document.source.get("/outputBindings")?.text()).toBe("{}");
      expect(document.source.get("/profiles/0/manualOpaque")?.text()).toBe(
        '{"number":1e+03}',
      );
      expect(() =>
        projectSavedController(
          { document, authorityRevision: stored.revision },
          {
            profileId: originalId,
            authorityRevision: stored.revision,
            sourceSha256: digest(document.source.text()),
          },
          { generation: "1", revision: "1" },
          { width: 874, height: 393 },
          digest,
        ),
      ).toThrow("saved_controller_unbound_control");
    } finally {
      repository.close();
      rmSync(root, { recursive: true, force: true });
    }
  },
  10000,
);
