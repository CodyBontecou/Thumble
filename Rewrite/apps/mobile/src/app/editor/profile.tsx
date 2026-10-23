import { Stack, useRouter } from "expo-router";
import { Button, FlatList, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useColors } from "../../theme/colors";
import { useEditor } from "../../editor/EditorProvider";
import {
  Body,
  EditorNotice,
  EditorProgress,
  EditorRow,
} from "../../editor/EditorComponents";
import { controlLabel } from "../../editor/editor-model";
export default function EditorProfile() {
  const { state, model } = useEditor();
  const colors = useColors(),
    insets = useSafeAreaInsets(),
    router = useRouter();
  return (
    <>
      <Stack.Screen options={{ title: state.current?.name ?? "Controls" }} />
      <FlatList
        testID="editor-controls"
        data={state.controls}
        keyExtractor={(item) => item.id}
        style={{ flex: 1, backgroundColor: colors.background }}
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={{
          paddingHorizontal: 24,
          paddingBottom: Math.max(24, insets.bottom + 16),
        }}
        ListHeaderComponent={
          <View style={{ paddingTop: 16, gap: 8 }}>
            <Body>
              {state.current
                ? "Tap a control to edit its label. Changes are kept on this phone until your Mac confirms them."
                : "Choose a profile from the editor first."}
            </Body>
            <EditorNotice />
            <EditorProgress />
            <Button
              testID="editor-review-changes"
              title={`Review changes${state.snapshot.queue.length ? ` (${state.snapshot.queue.length})` : ""}`}
              color={colors.accent}
              disabled={Boolean(state.busy)}
              onPress={() => router.push("/editor/queue")}
            />
          </View>
        }
        renderItem={({ item }) => (
          <EditorRow
            title={controlLabel(item)}
            action="Edit"
            detail={
              item.labelOverride !== null
                ? `Generated label: ${item.generatedLabel || "None"}`
                : "Generated label"
            }
            disabled={Boolean(state.busy)}
            testID={`editor-control-${item.id}`}
            onPress={() =>
              router.push({
                pathname: "/editor/label",
                params: { controlId: item.id },
              })
            }
          />
        )}
        ListEmptyComponent={
          <View style={{ paddingVertical: 24 }}>
            <Body>
              {state.current
                ? "This profile has no editable controls."
                : "Go back to choose a profile."}
            </Body>
          </View>
        }
        ListFooterComponent={
          state.nextControlOffset !== null ? (
            <Button
              title="Load more controls"
              disabled={Boolean(state.busy)}
              color={colors.accent}
              onPress={() => {
                void model.moreControls();
              }}
            />
          ) : (
            <View />
          )
        }
      />
    </>
  );
}
