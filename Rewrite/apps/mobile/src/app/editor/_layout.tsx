import { Stack, useRouter } from "expo-router";
import { Button } from "react-native";
import { EditorModel } from "../../editor/editor-model";
import { EditorProvider } from "../../editor/EditorProvider";
export default function EditorLayout({ model }: { model?: EditorModel } = {}) {
  const router = useRouter();
  return (
    <EditorProvider {...(model ? { model } : {})}>
      <Stack>
        <Stack.Screen
          name="index"
          options={{
            title: "Edit labels",
            headerLeft: () => (
              <Button title="Home" onPress={() => router.back()} />
            ),
          }}
        />
        <Stack.Screen name="profile" options={{ title: "Controls" }} />
        <Stack.Screen
          name="queue"
          options={{ title: "Changes on this phone", headerTransparent: false }}
        />
        <Stack.Screen
          name="label"
          options={{ title: "Edit label", presentation: "modal" }}
        />
      </Stack>
    </EditorProvider>
  );
}
