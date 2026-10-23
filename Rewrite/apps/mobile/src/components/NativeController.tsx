import { decodePhoneCatalogNotification } from "@thumble/contracts/phone-catalog";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  decodePhonePresentationNotification,
  type PhonePresentationNotification,
} from "@thumble/contracts/phone-presentation";
import {
  Image,
  Text,
  View,
  useColorScheme,
  type ViewProps,
} from "react-native";
import { requireNativeViewManager } from "expo-modules-core";
import { standardControllerMap } from "@thumble/domain/controller-layout";
import { useColors } from "../theme/colors";
import {
  decodePracticeAdmission,
  decodeControlMap,
  decodeConnectionAdmission,
  type ControlMap,
} from "@thumble/contracts/mobile-input";

const NativeView = requireNativeViewManager<
  ViewProps & {
    onCatalog: (event: { nativeEvent: { catalog: unknown } }) => void;
    practiceMap?: ControlMap;
    connect?: boolean;
    outputMode?: "recording" | "macos-hid";
    onControlMap: (event: {
      nativeEvent: { map: unknown; configurationSha256?: unknown };
    }) => void;
    onPresentation: (event: { nativeEvent: { presentation: unknown } }) => void;
    onAdmission: (event: { nativeEvent: { admission: unknown } }) => void;
  }
>("ThumbleNativeInput");
const labels: Record<string, string> = {
  south: "A",
  east: "B",
  west: "X",
  north: "Y",
  leftShoulder: "LB",
  rightShoulder: "RB",
  leftTrigger: "LT",
  rightTrigger: "RT",
  leftStick: "L",
  leftStandardStick: "L",
  rightStandardStick: "R",
  leftVerticalTrigger: "LT",
  leftHorizontalTrigger: "LT",
  rightVerticalTrigger: "RT",
  rightHorizontalTrigger: "RT",
  rightStick: "R",
  leftStickPress: "L3",
  rightStickPress: "R3",
  select: "Select",
  start: "Start",
  home: "Home",
  dpadUp: "↑",
  dpadDown: "↓",
  dpadLeft: "←",
  dpadRight: "→",
};
const map = standardControllerMap("1", "0");
type Presented = Extract<
  PhonePresentationNotification,
  { kind: "presentation" }
>;
type Visuals = Readonly<{
  metadata: Presented;
  icons: Readonly<Record<string, string>>;
  receivedAt: number;
  stale: boolean;
}>;
export function NativeController({
  connected = false,
  outputMode = "recording",
}: {
  connected?: boolean;
  outputMode?: "recording" | "macos-hid";
}) {
  const colors = useColors();
  const admittedSession = useRef<string | null>(null);
  const installed = useRef<{ map: ControlMap; hash: string | null } | null>(
    null,
  );
  const visuals = useRef<Visuals | null>(null);
  const [presentation, setPresentation] = useState<Visuals | null>(null);
  const scheme = useColorScheme() === "dark" ? "dark" : "light";
  const publishVisuals = useCallback((value: Visuals | null) => {
    visuals.current = value;
    setPresentation(value);
  }, []);
  useEffect(() => {
    publishVisuals(null);
  }, [connected, scheme, publishVisuals]);
  useEffect(() => {
    if (!presentation || presentation.stale) return;
    const timer = setInterval(() => {
      const current = visuals.current;
      if (!current) return;
      const age = performance.now() - current.receivedAt;
      if (age < 0 || age >= 6000) publishVisuals({ ...current, stale: true });
    }, 1000);
    return () => clearInterval(timer);
  }, [presentation?.metadata, presentation?.stale, publishVisuals]);
  const receivePresentation = useCallback(
    (event: { nativeEvent: { presentation: unknown } }) => {
      try {
        const value = decodePhonePresentationNotification(
          event.nativeEvent.presentation,
        );
        const pin = installed.current;
        if (
          !connected ||
          !pin ||
          !pin.hash ||
          admittedSession.current !== `${value.generation}:${value.revision}` ||
          pin.map.generation !== value.generation ||
          pin.map.revision !== value.revision ||
          pin.hash !== value.configurationSha256
        )
          return;
        const previous = visuals.current;
        if (value.kind === "error") {
          if (previous) publishVisuals({ ...previous, stale: true });
          return;
        }
        if (value.colorScheme !== scheme) return;
        if (value.kind === "presentation") {
          if (
            previous &&
            (value.expectedConfigurationRevision !==
              previous.metadata.expectedConfigurationRevision ||
              value.expectedSourceHash !==
                previous.metadata.expectedSourceHash ||
              value.profileId !== previous.metadata.profileId)
          )
            return;
          const ids = new Set(pin.map.controls.map((c) => c.id));
          if (
            value.controls.length !== ids.size ||
            value.controls.some((c) => !ids.has(c.id))
          )
            return;
          if (
            previous &&
            (BigInt(value.presentationRevision) <
              BigInt(previous.metadata.presentationRevision) ||
              (value.presentationRevision ===
                previous.metadata.presentationRevision &&
                value.presentationSourceHash !==
                  previous.metadata.presentationSourceHash))
          )
            return;
          const icons: Record<string, string> = Object.create(null);
          for (const control of value.controls) {
            const old = previous?.metadata.controls.find(
              (c) => c.id === control.id,
            );
            if (
              old?.iconSHA256 &&
              old.iconSHA256 === control.iconSHA256 &&
              previous?.icons[control.id]
            )
              icons[control.id] = previous.icons[control.id]!;
          }
          publishVisuals({
            metadata: value,
            icons,
            receivedAt: performance.now(),
            stale: false,
          });
        } else if (
          previous &&
          value.presentationRevision ===
            previous.metadata.presentationRevision &&
          value.presentationSourceHash ===
            previous.metadata.presentationSourceHash &&
          value.colorScheme === previous.metadata.colorScheme &&
          value.expectedConfigurationRevision ===
            previous.metadata.expectedConfigurationRevision &&
          value.expectedSourceHash === previous.metadata.expectedSourceHash &&
          value.profileId === previous.metadata.profileId &&
          previous.metadata.controls.some(
            (c) =>
              c.id === value.controlId && c.iconSHA256 === value.iconSHA256,
          )
        ) {
          publishVisuals({
            ...previous,
            icons: {
              ...previous.icons,
              [value.controlId]: `data:image/png;base64,${value.pngBase64}`,
            },
          });
        }
      } catch {
        const previous = visuals.current;
        if (previous) publishVisuals({ ...previous, stale: true });
      }
    },
    [connected, scheme, publishVisuals],
  );
  const [admissionEpoch, setAdmissionEpoch] = useState<string | null>(null);
  const [installedMap, setInstalledMap] = useState<ControlMap | null>(null);
  const receiveMap = useCallback(
    (event: {
      nativeEvent: { map: unknown; configurationSha256?: unknown };
    }) => {
      try {
        const next = decodeControlMap(event.nativeEvent.map);
        const hash = event.nativeEvent.configurationSha256;
        installed.current = {
          map: next,
          hash:
            typeof hash === "string" && /^[a-f0-9]{64}$/.test(hash)
              ? hash
              : null,
        };
        publishVisuals(null);
        setInstalledMap(next);
      } catch {
        installed.current = null;
        publishVisuals(null);
        setInstalledMap(null);
      }
    },
    [publishVisuals],
  );
  const [catalogSummary, setCatalogSummary] = useState<string | null>(null);
  const receiveCatalog = useCallback(
    (event: { nativeEvent: { catalog: unknown } }) => {
      try {
        const catalog = decodePhoneCatalogNotification(
          event.nativeEvent.catalog,
        );
        if (catalog.kind === "error") {
          setCatalogSummary("Saved profiles unavailable");
          return;
        }
        const count = catalog.profileCount;
        setCatalogSummary(
          count === 0
            ? "No saved profiles"
            : `${count} saved profile${count === 1 ? "" : "s"}${catalog.nextOffset === null ? "" : " · More available"}`,
        );
      } catch {
        setCatalogSummary("Saved profiles unavailable");
      }
    },
    [],
  );
  const [phase, setPhase] = useState<string>("starting");
  const admit = useCallback(
    (event: { nativeEvent: { admission: unknown } }) => {
      try {
        if (connected) {
          const ack = decodeConnectionAdmission(event.nativeEvent.admission);
          if (ack.status === "ready") {
            const session = `${ack.generation}:${ack.revision}`;
            if (
              admittedSession.current !== null &&
              admittedSession.current !== session
            ) {
              setCatalogSummary(null);
              const incoming = installed.current?.map;
              if (
                !incoming ||
                `${incoming.generation}:${incoming.revision}` !== session
              )
                installed.current = null;
              publishVisuals(null);
            }
            admittedSession.current = session;
            setAdmissionEpoch(session);
            setInstalledMap((previous) =>
              previous &&
              `${previous.generation}:${previous.revision}` === session
                ? previous
                : null,
            );
          } else {
            admittedSession.current = null;
            installed.current = null;
            publishVisuals(null);
            setAdmissionEpoch(null);
            setInstalledMap(null);
            setCatalogSummary(null);
          }
          setPhase(ack.status);
          return;
        }
        const ack = decodePracticeAdmission(event.nativeEvent.admission);
        if (
          ack.status !== "ready" ||
          ack.generation !== map.generation ||
          ack.revision !== map.revision
        )
          throw new Error("practice_admission_mismatch");
        setPhase("ready");
      } catch {
        admittedSession.current = null;
        installed.current = null;
        publishVisuals(null);
        setAdmissionEpoch(null);
        setInstalledMap(null);
        setCatalogSummary(null);
        setPhase("error");
      }
    },
    [connected, publishVisuals],
  );
  const renderMap = connected
    ? phase === "ready" &&
      installedMap &&
      `${installedMap.generation}:${installedMap.revision}` === admissionEpoch
      ? installedMap
      : null
    : map;
  return (
    <View style={{ flex: 1 }}>
      <View
        pointerEvents="none"
        accessible={false}
        style={{ position: "absolute", inset: 0 }}
      >
        {renderMap?.controls.map((control) => (
          <View
            key={control.id}
            style={{
              position: "absolute",
              left: `${control.x * 100}%`,
              top: `${control.y * 100}%`,
              width: `${control.width * 100}%`,
              height: `${control.height * 100}%`,
              borderWidth: 1,
              borderColor: colors.separator,
              borderRadius: control.action.endsWith("StandardStick") ? 999 : 12,
              borderCurve: "continuous",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            {presentation?.icons[control.id] ? (
              <Image
                testID={`presentation-icon-${control.id}`}
                source={{ uri: presentation.icons[control.id] }}
                resizeMode="contain"
                accessible={false}
                style={{
                  width: 32,
                  height: 32,
                  maxWidth: "80%",
                  maxHeight: "80%",
                  opacity:
                    presentation.stale ||
                    presentation.metadata.freshness === "stale"
                      ? 0.5
                      : 1,
                }}
              />
            ) : (
              <Text
                numberOfLines={1}
                adjustsFontSizeToFit
                minimumFontScale={0.8}
                maxFontSizeMultiplier={1.2}
                style={{
                  color: colors.label,
                  fontSize: 14,
                  fontWeight: "600",
                }}
              >
                {presentation?.metadata.controls.find(
                  (c) => c.id === control.id,
                )?.label || labels[control.action]}
              </Text>
            )}
          </View>
        ))}
      </View>
      <NativeView
        {...(connected ? { outputMode } : {})}
        {...(connected ? { connect: true } : { practiceMap: map })}
        onAdmission={admit}
        onCatalog={receiveCatalog}
        onControlMap={receiveMap}
        onPresentation={receivePresentation}
        testID="controller-surface"
        pointerEvents={phase === "ready" ? "auto" : "none"}
        accessibilityLabel={
          connected ? "Connected controller" : "Practice controller"
        }
        style={{ flex: 1, backgroundColor: "transparent" }}
      />
      {!["error", "unavailable", "cancelled", "disconnected"].includes(
        phase,
      ) && (
        <Text
          testID={
            connected
              ? `connection-${phase}`
              : phase === "ready"
                ? "practice-ready"
                : "practice-starting"
          }
          maxFontSizeMultiplier={1.3}
          pointerEvents="none"
          style={{
            position: "absolute",
            top: 0,
            left: "30%",
            right: "30%",
            textAlign: "center",
            fontSize: 13,
            color: colors.secondaryLabel,
          }}
        >
          {connected
            ? ({
                ready: "Connected to receiver",
                waiting: "Waiting for invitation",
                pairing: "Saving phone trust…",
                connecting: "Connecting…",
              }[phase] ?? "Starting connection…")
            : phase === "ready"
              ? "Practice ready"
              : "Starting practice…"}
        </Text>
      )}
      {connected && phase === "ready" && presentation && (
        <Text
          testID="presentation-status"
          pointerEvents="none"
          numberOfLines={1}
          maxFontSizeMultiplier={1.3}
          style={{
            position: "absolute",
            top: 20,
            left: "30%",
            right: "30%",
            textAlign: "center",
            fontSize: 12,
            color: colors.secondaryLabel,
          }}
        >
          {presentation.stale || presentation.metadata.freshness === "stale"
            ? "Game data stale"
            : presentation.metadata.freshness === "observed"
              ? "Game data live"
              : "Game data not checked"}
        </Text>
      )}
      {connected && phase === "ready" && catalogSummary !== null && (
        <Text
          testID="saved-profile-summary"
          pointerEvents="none"
          maxFontSizeMultiplier={1.3}
          numberOfLines={2}
          style={{
            position: "absolute",
            bottom: 8,
            left: "25%",
            right: "25%",
            textAlign: "center",
            fontSize: 13,
            color: colors.secondaryLabel,
          }}
        >
          {catalogSummary}
        </Text>
      )}
      {["error", "unavailable", "cancelled", "disconnected"].includes(
        phase,
      ) && (
        <Text
          accessibilityRole="alert"
          style={{
            color: colors.error,
            position: "absolute",
            left: 16,
            right: 16,
            top: 8,
          }}
        >
          {connected
            ? phase === "cancelled"
              ? "Connection cancelled. Close this controller to try again."
              : phase === "disconnected"
                ? "Disconnected. Close and reconnect to start with released controls."
                : "Ask your agent to start the receiver and open pairing, then try again."
            : "The controller could not start. Close practice and try again."}
        </Text>
      )}
    </View>
  );
}
