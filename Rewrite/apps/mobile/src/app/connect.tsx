import { useLocalSearchParams, useRouter } from "expo-router";
import { Pressable, Text } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useColors } from "../theme/colors";
import { ControllerScreen } from "./practice";

export default function Connect() {
  const colors = useColors();
  const { outputMode } = useLocalSearchParams<{ outputMode?: string }>();
  const router = useRouter();
  // Missing intent preserves existing diagnostic routes; malformed intent never
  // reaches a native owner or silently changes physical output into a test.
  if (
    outputMode !== undefined &&
    outputMode !== "recording" &&
    outputMode !== "macos-hid"
  ) {
    return (
      <SafeAreaView
        style={{
          flex: 1,
          justifyContent: "center",
          padding: 24,
          gap: 24,
          backgroundColor: colors.background,
        }}
      >
        <Text
          testID="connection-invalid-intent"
          style={{ fontSize: 17, color: colors.label }}
        >
          Choose a connection from Home.
        </Text>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Back to Home"
          testID="connection-invalid-done"
          onPress={() => router.replace("/")}
          style={{
            minHeight: 44,
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <Text style={{ fontSize: 17, color: colors.accent }}>
            Back to Home
          </Text>
        </Pressable>
      </SafeAreaView>
    );
  }
  return <ControllerScreen connected outputMode={outputMode ?? "recording"} />;
}
