import {
  Stack,
  useLocalSearchParams,
  usePreventRemove,
  useRouter,
} from "expo-router";
import { useEffect, useRef, useState, type ComponentRef } from "react";
import {
  Alert,
  Button,
  Keyboard,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  Text,
  TextInput,
  View,
} from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useColors } from "../../theme/colors";
import { useEditor } from "../../editor/EditorProvider";
import { Body, EditorNotice } from "../../editor/EditorComponents";
import { newEditorOperationId } from "../../editor/editor-model";
import type { EditorEnqueue } from "../../editor/NativeEditorSession";
export default function EditorLabel() {
  const { state, model } = useEditor();
  const params = useLocalSearchParams<{ controlId?: string }>();
  const colors = useColors(),
    insets = useSafeAreaInsets(),
    router = useRouter();
  const control =
    typeof params.controlId === "string"
      ? state.controls.find((item) => item.id === params.controlId)
      : undefined;
  const draft = useRef(
    state.current && control
      ? { profile: state.current, control, operationId: newEditorOperationId() }
      : null,
  ).current;
  const [mode, setMode] = useState<"custom" | "blank" | "generated">(
    draft?.control.labelOverride === null
      ? "generated"
      : draft?.control.labelOverride === ""
        ? "blank"
        : "custom",
  );
  const text = useRef(
    draft?.control.labelOverride ?? draft?.control.generatedLabel ?? "",
  );
  const input = useRef<ComponentRef<typeof TextInput>>(null);
  const [dirty, setDirty] = useState(false),
    [saving, setSaving] = useState(false),
    [attempted, setAttempted] = useState(false);
  const attempt = useRef<EditorEnqueue | null>(null);
  const initialText =
    draft?.control.labelOverride ?? draft?.control.generatedLabel ?? "";
  const disablePrevention = usePreventRemove(dirty || saving, ({ repeat }) => {
    if (saving) return;
    Alert.alert(
      "Leave this label?",
      "Text you haven’t queued will be discarded. Changes already kept on this phone stay in the queue.",
      [
        { text: "Keep editing", style: "cancel" },
        {
          text: "Discard draft",
          style: "destructive",
          onPress: () => {
            setDirty(false);
            repeat();
          },
        },
      ],
    );
  });
  useEffect(() => {
    if (mode === "custom" && dirty && !attempted) input.current?.focus();
  }, [mode, dirty, attempted]);
  function choose(next: typeof mode) {
    Keyboard.dismiss();
    model.clearNotice();
    setMode(next);
    setDirty(true);
  }
  function blank() {
    Alert.alert(
      "Use a blank label?",
      "The control will still work, but its label will be hidden.",
      [
        { text: "Cancel", style: "cancel" },
        { text: "Use blank label", onPress: () => choose("blank") },
      ],
    );
  }
  async function queue() {
    if (!draft || saving || state.busy) return;
    if (!attempt.current) {
      const label =
        mode === "generated" ? null : mode === "blank" ? "" : text.current;
      if (mode === "custom" && label === "") {
        Alert.alert(
          "Choose a blank label",
          "To hide the label deliberately, choose “Use blank label” below.",
        );
        return;
      }
      if (label !== null && Array.from(label).length > 256) {
        Alert.alert("Label is too long", "Use at most 256 characters.");
        return;
      }
      attempt.current = Object.freeze({
        contextId: draft.profile.contextId,
        expectedRevision: draft.profile.revision,
        sourceSha256: draft.profile.sourceSha256,
        controlId: draft.control.id,
        operationId: draft.operationId,
        label,
      });
      setAttempted(true);
    }
    Keyboard.dismiss();
    setSaving(true);
    const queued = await model.enqueue(attempt.current);
    setSaving(false);
    if (queued) {
      setDirty(false);
      disablePrevention();
      router.back();
    }
  }
  return (
    <>
      <Stack.Screen
        options={{
          title: "Edit label",
          headerLeft: () => (
            <Button
              title="Cancel"
              testID="editor-label-cancel"
              disabled={saving}
              color={colors.accent}
              onPress={() => router.back()}
            />
          ),
          headerRight: () => (
            <Button
              testID="editor-queue-label"
              title={saving ? "Keeping…" : attempted ? "Retry" : "Queue"}
              disabled={!draft || saving || Boolean(state.busy)}
              color={colors.accent}
              onPress={() => {
                void queue();
              }}
            />
          ),
        }}
      />
      <KeyboardAvoidingView
        style={{ flex: 1, backgroundColor: colors.background }}
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        keyboardVerticalOffset={insets.top}
      >
        <ScrollView
          testID="editor-label"
          contentInsetAdjustmentBehavior="automatic"
          keyboardShouldPersistTaps="handled"
          contentContainerStyle={{
            paddingHorizontal: 24,
            paddingTop: 24,
            paddingBottom: Math.max(24, insets.bottom + 16),
            gap: 24,
          }}
        >
          {!draft ? (
            <Body>
              Choose a control from a profile before editing its label.
            </Body>
          ) : (
            <>
              <View style={{ gap: 8 }}>
                <Text
                  style={{
                    fontSize: 17,
                    fontWeight: "600",
                    color: colors.label,
                  }}
                >
                  Label
                </Text>
                <TextInput
                  ref={input}
                  testID="editor-label-input"
                  accessibilityLabel="Control label"
                  key={mode}
                  defaultValue={
                    mode === "custom"
                      ? text.current
                      : mode === "blank"
                        ? ""
                        : draft.control.generatedLabel
                  }
                  placeholder={
                    mode === "blank"
                      ? "Blank label"
                      : "Generated label is blank"
                  }
                  editable={mode === "custom" && !attempted && !saving}
                  maxLength={512}
                  returnKeyType="done"
                  onSubmitEditing={Keyboard.dismiss}
                  onChangeText={(value) => {
                    text.current = value;
                    setDirty(
                      value !== initialText ||
                        draft.control.labelOverride === null,
                    );
                  }}
                  style={{
                    minHeight: 52,
                    borderWidth: 1,
                    borderColor: colors.separator,
                    borderRadius: 8,
                    borderCurve: "continuous",
                    padding: 12,
                    fontSize: 20,
                    color: colors.label,
                    opacity: mode === "custom" ? 1 : 0.6,
                  }}
                />
                <Body>
                  {mode === "generated"
                    ? `Use the generated label: ${draft.control.generatedLabel || "Blank"}`
                    : mode === "blank"
                      ? "Use a deliberately blank label. The control still works."
                      : "Write a custom label, up to 256 characters."}
                </Body>
              </View>
              <View style={{ gap: 16 }}>
                <Button
                  testID="editor-write-custom"
                  title="Write custom label"
                  disabled={attempted || saving}
                  color={colors.accent}
                  onPress={() => choose("custom")}
                />
                <Button
                  testID="editor-use-blank"
                  title="Use blank label"
                  disabled={attempted || saving}
                  color={colors.accent}
                  onPress={blank}
                />
                <Button
                  testID="editor-use-generated"
                  title="Use generated label"
                  disabled={attempted || saving}
                  color={colors.accent}
                  onPress={() => choose("generated")}
                />
              </View>
              {attempted && !saving && (
                <Body>
                  A retry keeps this exact change. To write something else,
                  cancel this draft and review the queue first.
                </Body>
              )}
              {attempted && <EditorNotice />}
              <Body>
                Queueing keeps the change on this phone. Your Mac must confirm
                it before it is shown as saved.
              </Body>
            </>
          )}
        </ScrollView>
      </KeyboardAvoidingView>
    </>
  );
}
