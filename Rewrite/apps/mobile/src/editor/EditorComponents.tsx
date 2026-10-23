import type { ReactNode } from "react";
import { ActivityIndicator, Button, Pressable, Text, View } from "react-native";
import { useColors } from "../theme/colors";
import { useEditor } from "./EditorProvider";
export function SectionTitle({ children }: { children: ReactNode }) {
  const colors = useColors();
  return (
    <Text
      accessibilityRole="header"
      style={{
        fontSize: 20,
        fontWeight: "600",
        color: colors.label,
        marginTop: 24,
        marginBottom: 8,
      }}
    >
      {children}
    </Text>
  );
}
export function Body({ children }: { children: ReactNode }) {
  const colors = useColors();
  return (
    <Text
      style={{ fontSize: 17, lineHeight: 25, color: colors.secondaryLabel }}
    >
      {children}
    </Text>
  );
}
export function EditorNotice() {
  const { state } = useEditor();
  const colors = useColors();
  if (!state.notice) return null;
  return (
    <View
      accessibilityLiveRegion="polite"
      style={{ gap: 8, paddingVertical: 16 }}
      testID="editor-notice"
    >
      <Text
        style={{
          fontSize: 17,
          fontWeight: "600",
          color: state.notice.error ? colors.error : colors.label,
        }}
      >
        {state.notice.title}
      </Text>
      <Body>{state.notice.detail}</Body>
    </View>
  );
}
export function EditorProgress() {
  const { state, model } = useEditor();
  const colors = useColors();
  if (!state.busy) return null;
  return (
    <View
      style={{ gap: 8, paddingVertical: 12 }}
      accessibilityLiveRegion="polite"
    >
      <View style={{ flexDirection: "row", gap: 12, alignItems: "center" }}>
        <ActivityIndicator color={colors.accent} />
        <Text style={{ flex: 1, fontSize: 17, color: colors.secondaryLabel }}>
          {state.busy}
        </Text>
      </View>
      {state.busy !== "Keeping your change…" && (
        <Button
          title="Cancel request"
          onPress={() => {
            void model.cancel();
          }}
          color={colors.accent}
        />
      )}
    </View>
  );
}
export function EditorRow({
  title,
  detail,
  action = "Open",
  onPress,
  disabled = false,
  testID,
}: {
  title: string;
  detail?: string;
  action?: string;
  onPress: () => void;
  disabled?: boolean;
  testID?: string;
}) {
  const colors = useColors();
  return (
    <Pressable
      testID={testID}
      onPress={onPress}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={detail ? `${title}, ${detail}` : title}
      accessibilityHint={action}
      accessibilityState={{ disabled }}
      style={({ pressed }) => ({
        minHeight: 64,
        paddingVertical: 16,
        flexDirection: "row",
        alignItems: "center",
        gap: 16,
        borderBottomWidth: 0.5,
        borderColor: colors.separator,
        opacity: disabled ? 0.5 : pressed ? 0.6 : 1,
      })}
    >
      <View style={{ flex: 1, gap: 4 }}>
        <Text style={{ fontSize: 17, color: colors.label }}>{title}</Text>
        {detail && (
          <Text
            style={{
              fontSize: 15,
              lineHeight: 21,
              color: colors.secondaryLabel,
            }}
          >
            {detail}
          </Text>
        )}
      </View>
      <Text style={{ fontSize: 15, color: colors.accent }}>{action}</Text>
    </Pressable>
  );
}
