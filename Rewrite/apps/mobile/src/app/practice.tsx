import { useRouter } from "expo-router";
import { Pressable, Text, View, useWindowDimensions } from "react-native";
import { StatusBar } from "expo-status-bar";
import { SafeAreaView } from "react-native-safe-area-context";
import { NativeController } from "../components/NativeController";
import { colors } from "../theme/colors";
export default function Practice() {
  const router = useRouter(),
    { width, height } = useWindowDimensions();
  return (
    <SafeAreaView
      testID="practice-screen"
      style={{ flex: 1, backgroundColor: colors.background }}
    >
      <StatusBar hidden={width > height} />
      <View style={{ flex: 1 }}>
        {width > height ? (
          <NativeController />
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
              Practice uses the landscape controller layout.
            </Text>
          </View>
        )}
        <Pressable
          testID="practice-done"
          accessibilityRole="button"
          accessibilityLabel="Done"
          onPress={() => router.back()}
          style={({ pressed }) => ({
            position: "absolute",
            top: 0,
            right: 0,
            minWidth: 60,
            minHeight: 44,
            alignItems: "center",
            justifyContent: "center",
            opacity: pressed ? 0.65 : 1,
          })}
        >
          <Text
            style={{ fontSize: 17, fontWeight: "600", color: colors.accent }}
          >
            Done
          </Text>
        </Pressable>
      </View>
    </SafeAreaView>
  );
}
