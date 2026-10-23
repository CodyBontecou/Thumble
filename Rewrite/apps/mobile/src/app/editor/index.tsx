import { useRouter } from "expo-router";
import { ActivityIndicator, Button, FlatList, Text, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useColors } from "../../theme/colors";
import { useEditor } from "../../editor/EditorProvider";
import {
  Body,
  EditorNotice,
  EditorProgress,
  EditorRow,
  SectionTitle,
} from "../../editor/EditorComponents";
import type { EditorCacheSummary } from "../../editor/NativeEditorSession";
import type { CatalogProfile } from "../../editor/editor-model";
type Row =
  | { kind: "heading"; title: string; key: string }
  | { kind: "cached"; profile: EditorCacheSummary; key: string }
  | { kind: "current"; profile: CatalogProfile; key: string }
  | { kind: "empty"; text: string; key: string };
export default function EditorHome() {
  const { state, model } = useEditor();
  const colors = useColors(),
    insets = useSafeAreaInsets(),
    router = useRouter();
  const rows: Row[] = [
    { kind: "heading", title: "On this phone", key: "cached-title" },
    ...state.snapshot.profiles.map((profile) => ({
      kind: "cached" as const,
      profile,
      key: profile.contextId,
    })),
  ];
  if (!state.snapshot.profiles.length)
    rows.push({
      kind: "empty",
      key: "no-cache",
      text: "No saved profiles yet. Refresh profiles while connected to your Mac, then open one to keep a copy here.",
    });
  rows.push({ kind: "heading", key: "current-title", title: "On your Mac" });
  for (const profile of state.catalog?.profiles ?? [])
    rows.push({ kind: "current", profile, key: `mac-${profile.id}` });
  if (state.catalog && !state.catalog.profiles.length)
    rows.push({
      kind: "empty",
      key: "no-current",
      text: "There are no profiles on your Mac. Ask your agent to create one.",
    });
  const disabled = Boolean(state.busy) || state.phase !== "ready";
  return (
    <FlatList
      testID="editor-home"
      data={rows}
      keyExtractor={(item) => item.key}
      style={{ flex: 1, backgroundColor: colors.background }}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={{
        paddingHorizontal: 24,
        paddingBottom: Math.max(24, insets.bottom + 16),
      }}
      ListHeaderComponent={
        <View style={{ gap: 16, paddingTop: 16 }}>
          <Body>
            Change a control’s label without changing what it does. Profiles
            kept on this phone work offline.
          </Body>
          {state.phase === "opening" && (
            <ActivityIndicator
              accessibilityLabel="Opening editor"
              color={colors.accent}
            />
          )}
          <EditorNotice />
          <EditorProgress />
          {state.phase === "unavailable" && (
            <Button
              title="Try opening again"
              onPress={() => {
                void model.open();
              }}
              color={colors.accent}
            />
          )}
          {state.phase === "ready" && (
            <EditorRow
              title="Changes on this phone"
              detail={
                state.snapshot.queue.length
                  ? `${state.snapshot.queue.length} waiting to be confirmed`
                  : "No pending changes"
              }
              action="Review"
              testID="editor-open-queue"
              onPress={() => router.push("/editor/queue")}
              disabled={Boolean(state.busy)}
            />
          )}
        </View>
      }
      renderItem={({ item }) => {
        if (item.kind === "heading")
          return (
            <View>
              <SectionTitle>{item.title}</SectionTitle>
              {item.key === "current-title" && (
                <View style={{ gap: 8, marginBottom: 8 }}>
                  <Body>
                    Refresh to read current profiles. Your queued edits stay
                    separate.
                  </Body>
                  <Button
                    title="Refresh profiles"
                    disabled={disabled}
                    color={colors.accent}
                    onPress={() => {
                      void model.refreshCatalog();
                    }}
                  />
                </View>
              )}
            </View>
          );
        if (item.kind === "empty")
          return (
            <View style={{ paddingVertical: 8 }}>
              <Body>{item.text}</Body>
            </View>
          );
        if (item.kind === "cached")
          return (
            <EditorRow
              title={item.profile.name}
              detail={`${item.profile.controlCount} controls · saved on this phone`}
              disabled={disabled}
              testID={`editor-cached-${item.profile.contextId}`}
              onPress={() => {
                void model.openCached(item.profile.contextId).then((opened) => {
                  if (opened) router.push("/editor/profile");
                });
              }}
            />
          );
        return (
          <EditorRow
            title={item.profile.name}
            detail="Read a current copy from your Mac"
            disabled={disabled}
            onPress={() => {
              void model.openCurrent(item.profile.id).then((opened) => {
                if (opened) router.push("/editor/profile");
              });
            }}
          />
        );
      }}
      ListFooterComponent={
        state.catalog?.nextOffset !== null &&
        state.catalog?.nextOffset !== undefined ? (
          <Button
            title="Load more profiles"
            disabled={disabled}
            color={colors.accent}
            onPress={() => {
              void model.moreCatalog();
            }}
          />
        ) : (
          <View style={{ height: 16 }} />
        )
      }
    />
  );
}
