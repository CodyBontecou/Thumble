import { useEffect, useRef, useState } from "react";
import type { EditorQueueEntry } from "../../editor/NativeEditorSession";
import { Button, FlatList, Text, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useColors } from "../../theme/colors";
import { useEditor } from "../../editor/EditorProvider";
import {
  Body,
  EditorNotice,
  EditorProgress,
} from "../../editor/EditorComponents";
const statuses = {
  queued: "Ready to send",
  uncertain: "Waiting for confirmation",
  conflict: "Needs review",
  rejected: "Needs help from your agent",
} as const;
export default function EditorQueue() {
  const { state, model } = useEditor();
  const list = useRef<FlatList<EditorQueueEntry>>(null);
  const [activeOperation, setActiveOperation] = useState<string | null>(null);
  useEffect(() => {
    if (state.notice)
      list.current?.scrollToOffset({ offset: 0, animated: false });
  }, [state.notice]);
  const colors = useColors(),
    insets = useSafeAreaInsets();
  return (
    <FlatList
      ref={list}
      testID="editor-queue"
      data={state.snapshot.queue}
      keyExtractor={(item) => item.operationId}
      style={{ flex: 1, backgroundColor: colors.background }}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={{
        paddingHorizontal: 24,
        paddingBottom: Math.max(24, insets.bottom + 16),
      }}
      ListHeaderComponent={
        <View style={{ gap: 12, paddingTop: 16 }}>
          <Body>
            These are the original changes kept on this phone. Checking a change
            never moves it to a different copy of a profile.
          </Body>
          <EditorNotice />
          <EditorProgress />
        </View>
      }
      renderItem={({ item }) => (
        <View
          testID={`editor-queue-${item.operationId}`}
          style={{
            gap: 12,
            paddingVertical: 20,
            borderBottomWidth: 0.5,
            borderColor: colors.separator,
          }}
        >
          <Text
            accessibilityRole="header"
            style={{ color: colors.label, fontSize: 17, fontWeight: "600" }}
          >
            {statuses[item.status]}
          </Text>
          <Text selectable style={{ color: colors.label, fontSize: 20 }}>
            {item.label === null
              ? "Use the generated label"
              : item.label === ""
                ? "Use a blank label"
                : `Label: ${item.label}`}
          </Text>
          <Body>
            {item.status === "queued"
              ? "Kept on this phone. It has not been saved on your Mac."
              : item.status === "conflict"
                ? "The profile changed on your Mac. The original edit is kept here for review."
                : item.status === "rejected"
                  ? "Keep this change and ask your agent to help recover it."
                  : "Your Mac may have received this edit. Check its status before trying anything else."}
          </Body>
          <Button
            testID={`editor-${item.status === "queued" ? "send" : "status"}-${item.operationId}`}
            title={
              state.busy && activeOperation === item.operationId
                ? item.status === "queued"
                  ? "Sending…"
                  : "Checking…"
                : item.status === "queued"
                  ? "Send original change"
                  : "Check status"
            }
            color={colors.accent}
            disabled={Boolean(state.busy)}
            onPress={() => {
              setActiveOperation(item.operationId);
              void model
                .dispatch(item.operationId, item.status !== "queued")
                .finally(() => setActiveOperation(null));
            }}
          />
        </View>
      )}
      ListEmptyComponent={
        <View style={{ paddingVertical: 24, gap: 12 }}>
          <Text
            style={{ color: colors.label, fontSize: 22, fontWeight: "600" }}
          >
            No pending changes
          </Text>
          <Body>
            Edits you queue will appear here until your Mac confirms them.
          </Body>
        </View>
      }
    />
  );
}
