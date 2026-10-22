import { useRouter } from "expo-router";
import { Pressable, Text, View, useWindowDimensions } from "react-native";
import { StatusBar } from "expo-status-bar";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { NativeController } from "../components/NativeController";
import { colors } from "../theme/colors";
export function ControllerScreen({
  connected = false,
  outputMode = "recording",
}: {
  connected?: boolean;
  outputMode?: "recording" | "macos-hid";
}) {
  const insets = useSafeAreaInsets();
  const router = useRouter(),
    { width, height } = useWindowDimensions();
  const done = (
    <Pressable
      testID={connected ? "connection-done" : "practice-done"}
      accessibilityRole="button"
      accessibilityLabel="Done"
      onPress={() => router.back()}
      style={({ pressed }) => ({
        ...(connected
          ? {}
          : { position: "absolute" as const, top: 0, right: 0 }),
        minWidth: 60,
        minHeight: 44,
        alignItems: "center",
        justifyContent: "center",
        opacity: pressed ? 0.65 : 1,
      })}
    >
      <Text style={{ fontSize: 17, fontWeight: "600", color: colors.accent }}>
        Done
      </Text>
    </Pressable>
  );
  return (
    <View
      testID={connected ? "connection-screen" : "practice-screen"}
      style={{
        flex: 1,
        backgroundColor: colors.background,
        paddingTop: insets.top,
        paddingRight: insets.right,
        paddingBottom: insets.bottom,
        paddingLeft: insets.left,
      }}
    >
      <StatusBar hidden={width > height} />
      {connected && (
        <View
          testID="connection-header"
          style={{
            minHeight: 44,
            flexDirection: "row",
            alignItems: "center",
            justifyContent: "space-between",
            paddingLeft: 16,
          }}
        >
          <Text
            testID="connection-mode"
            style={{ fontSize: 17, fontWeight: "600", color: colors.label }}
          >
            {outputMode === "macos-hid" ? "Mac input" : "Test mode"}
          </Text>
          {done}
        </View>
      )}
      <View style={{ flex: 1 }}>
        {width > height ? (
          <NativeController
            key={connected ? outputMode : "practice"}
            connected={connected}
            outputMode={outputMode}
          />
        ) : (
          <View
            testID="practice-orientation"
            style={{
              flex: 1,
              alignItems: "center",
              justifyContent: "center",
              padding: 24,
              gap: 16,
            }}
          >
            <Text
              testID="practice-orientation-message"
              style={{ fontSize: 22, fontWeight: "600", color: colors.label }}
            >
              Turn your phone sideways
            </Text>
            <Text
              style={{
                fontSize: 17,
                color: colors.secondaryLabel,
                textAlign: "center",
              }}
            >
              {connected
                ? "The connected controller uses the landscape layout."
                : "Practice uses the landscape controller layout."}
            </Text>
          </View>
        )}
        {!connected && done}
      </View>
    </View>
  );
}

export default function Practice() {
  return <ControllerScreen />;
}
