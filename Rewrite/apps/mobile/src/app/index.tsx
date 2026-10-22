import { useRouter } from "expo-router";
import { Pressable, ScrollView, Text } from "react-native";
import { colors } from "../theme/colors";
export default function Home() {
  const router = useRouter();
  return (
    <ScrollView
      testID="home-screen"
      contentInsetAdjustmentBehavior="automatic"
      style={{ backgroundColor: colors.background }}
      contentContainerStyle={{ padding: 24, gap: 24 }}
    >
      <Text style={{ fontSize: 28, fontWeight: "700", color: colors.label }}>
        Your controller
      </Text>
      <Text
        style={{ fontSize: 17, lineHeight: 25, color: colors.secondaryLabel }}
      >
        Connect to your Mac to play, or try the controls first.
      </Text>
      <Pressable
        onPress={() =>
          router.navigate({
            pathname: "/connect",
            params: { outputMode: "macos-hid" },
          })
        }
        testID="home-connect-mac"
        accessibilityRole="button"
        accessibilityLabel="Connect to Mac"
        style={({ pressed }) => ({
          minHeight: 52,
          justifyContent: "center",
          alignItems: "center",
          borderRadius: 12,
          borderCurve: "continuous",
          backgroundColor: colors.accent,
          opacity: pressed ? 0.65 : 1,
        })}
      >
        <Text
          style={{ fontSize: 17, fontWeight: "600", color: colors.background }}
        >
          Connect to Mac
        </Text>
      </Pressable>
      <Pressable
        onPress={() =>
          router.navigate({
            pathname: "/connect",
            params: { outputMode: "recording" },
          })
        }
        testID="home-connect"
        accessibilityRole="button"
        accessibilityLabel="Test a connection"
        style={({ pressed }) => ({
          minHeight: 52,
          justifyContent: "center",
          alignItems: "center",
          borderRadius: 12,
          borderCurve: "continuous",
          borderWidth: 1,
          borderColor: colors.separator,
          opacity: pressed ? 0.65 : 1,
        })}
      >
        <Text style={{ fontSize: 17, fontWeight: "600", color: colors.accent }}>
          Test a connection
        </Text>
      </Pressable>
      <Pressable
        onPress={() => router.navigate("/practice")}
        testID="home-practice"
        accessibilityRole="button"
        accessibilityLabel="Practice controls"
        style={({ pressed }) => ({
          minHeight: 52,
          justifyContent: "center",
          alignItems: "center",
          borderRadius: 12,
          borderCurve: "continuous",
          borderWidth: 1,
          borderColor: colors.separator,
          opacity: pressed ? 0.65 : 1,
        })}
      >
        <Text style={{ fontSize: 17, fontWeight: "600", color: colors.accent }}>
          Practice controls
        </Text>
      </Pressable>
    </ScrollView>
  );
}
