import { useCallback, useState } from "react";
import { Text, View, type ViewProps } from "react-native";
import { requireNativeViewManager } from "expo-modules-core";
import { standardControllerMap } from "@thumble/domain/controller-layout";
import { colors } from "../theme/colors";
import {
  decodePracticeAdmission,
  type ControlMap,
} from "@thumble/contracts/mobile-input";

const NativeView = requireNativeViewManager<
  ViewProps & {
    practiceMap: ControlMap;
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
export function NativeController() {
  const [phase, setPhase] = useState<"starting" | "ready" | "error">(
    "starting",
  );
  const admit = useCallback(
    (event: { nativeEvent: { admission: unknown } }) => {
      try {
        const ack = decodePracticeAdmission(event.nativeEvent.admission);
        if (
          ack.status !== "ready" ||
          ack.generation !== map.generation ||
          ack.revision !== map.revision
        )
          throw new Error("practice_admission_mismatch");
        setPhase("ready");
      } catch {
        setPhase("error");
      }
    },
    [],
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
        practiceMap={map}
        onAdmission={admit}
        testID="controller-surface"
        pointerEvents={phase === "ready" ? "auto" : "none"}
        accessibilityLabel="Practice controller"
        style={{ flex: 1, backgroundColor: "transparent" }}
      />
      {phase !== "error" && (
        <Text
          testID={phase === "ready" ? "practice-ready" : "practice-starting"}
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
          {phase === "ready" ? "Practice ready" : "Starting practice…"}
        </Text>
      )}
      {phase === "error" && (
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
          The controller could not start. Close practice and try again.
        </Text>
      )}
    </View>
  );
}
