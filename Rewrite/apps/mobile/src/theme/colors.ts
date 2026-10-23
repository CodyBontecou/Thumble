import { Platform, PlatformColor, useColorScheme } from "react-native";

const ios = Object.freeze({
  background: PlatformColor("systemBackgroundColor"),
  label: PlatformColor("labelColor"),
  secondaryLabel: PlatformColor("secondaryLabelColor"),
  separator: PlatformColor("separatorColor"),
  accent: PlatformColor("systemBlueColor"),
  error: PlatformColor("systemRedColor"),
});
// Match AppCompat's colorBackground and the named native semantic resources.
// Actual values change React color props on a system appearance event, including
// activities that handle uiMode without recreation. iOS keeps dynamic native colors.
const android = Object.freeze({
  light: Object.freeze({
    background: "#FAFAFA",
    label: "#1C1B1F",
    secondaryLabel: "#49454F",
    separator: "#CAC4D0",
    accent: "#007aff",
    error: "#d32f2f",
  }),
  dark: Object.freeze({
    background: "#303030",
    label: "#E6E1E5",
    secondaryLabel: "#CAC4D0",
    separator: "#49454F",
    accent: "#007aff",
    error: "#d32f2f",
  }),
});

export function useColors() {
  const scheme = useColorScheme();
  return Platform.OS === "ios"
    ? ios
    : android[scheme === "dark" ? "dark" : "light"];
}
