import { Platform, PlatformColor } from "react-native";

export const colors = Object.freeze(
  Platform.OS === "ios"
    ? {
        background: PlatformColor("systemBackgroundColor"),
        label: PlatformColor("labelColor"),
        secondaryLabel: PlatformColor("secondaryLabelColor"),
        separator: PlatformColor("separatorColor"),
        accent: PlatformColor("systemBlueColor"),
        error: PlatformColor("systemRedColor"),
      }
    : {
        background: PlatformColor("?android:attr/colorBackground"),
        label: PlatformColor("@color/thumble_label"),
        secondaryLabel: PlatformColor("@color/thumble_secondary_label"),
        separator: PlatformColor("@color/thumble_separator"),
        accent: "#007aff",
        error: "#d32f2f",
      },
);
