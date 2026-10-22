import { decodePhoneCatalogNotification } from "@thumble/contracts/phone-catalog";
import { useCallback, useRef, useState } from "react";
import { Text, View, type ViewProps } from "react-native";
import { requireNativeViewManager } from "expo-modules-core";
import { standardControllerMap } from "@thumble/domain/controller-layout";
import { colors } from "../theme/colors";
import {
  decodePracticeAdmission,
  decodeConnectionAdmission,
  type ControlMap,
} from "@thumble/contracts/mobile-input";

const NativeView = requireNativeViewManager<
  ViewProps & {
    onCatalog: (event: { nativeEvent: { catalog: unknown } }) => void;
    practiceMap?: ControlMap;
    connectionMap?: ControlMap;
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
export function NativeController({
  connected = false,
}: {
  connected?: boolean;
}) {
  const admittedSession = useRef<string | null>(null);
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
            )
              setCatalogSummary(null);
            admittedSession.current = session;
          } else {
            admittedSession.current = null;
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
        setCatalogSummary(null);
        setPhase("error");
      }
    },
    [connected],
  );
  return (
    <View style={{ flex: 1 }}>
      <View
        pointerEvents="none"
        accessible={false}
        style={{ position: "absolute", inset: 0 }}
      >
        {map.controls.map((control) => (
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
              borderRadius: 12,
              borderCurve: "continuous",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
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
              {labels[control.action]}
            </Text>
          </View>
        ))}
      </View>
      <NativeView
        {...(connected ? { connectionMap: map } : { practiceMap: map })}
        onAdmission={admit}
        onCatalog={receiveCatalog}
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
