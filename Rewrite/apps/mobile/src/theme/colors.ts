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
        label: PlatformColor("?android:attr/textColorPrimary"),
        secondaryLabel: PlatformColor("?android:attr/textColorSecondary"),
        separator: PlatformColor("?android:attr/textColorHint"),
        accent: "#007aff",
        error: "#d32f2f",
      },
);
