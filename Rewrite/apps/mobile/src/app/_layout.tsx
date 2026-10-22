import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from "expo-router";
import { useColorScheme } from "react-native";
import { StatusBar } from "expo-status-bar";
export const unstable_settings = { initialRouteName: "index" };
export default function Layout() {
  const dark = useColorScheme() === "dark";
  return (
    <ThemeProvider value={dark ? DarkTheme : DefaultTheme}>
      <StatusBar style={dark ? "light" : "dark"} />
      <Stack>
        <Stack.Screen name="index" options={{ title: "Thumble" }} />
        <Stack.Screen
          name="connect"
          options={{ headerShown: false, presentation: "fullScreenModal" }}
        />
        <Stack.Screen
          name="practice"
          options={{ headerShown: false, presentation: "fullScreenModal" }}
        />
      </Stack>
    </ThemeProvider>
  );
}
