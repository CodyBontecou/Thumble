import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useSyncExternalStore,
  type ReactNode,
} from "react";
import { EditorModel } from "./editor-model";
const EditorContext = createContext<EditorModel | null>(null);
export function EditorProvider({
  children,
  model: injected,
}: {
  children: ReactNode;
  model?: EditorModel;
}) {
  const model = useRef<EditorModel | null>(null);
  if (!model.current) model.current = injected ?? new EditorModel();
  const owner = model.current;
  const active = useRef(false);
  useEffect(() => {
    active.current = true;
    void owner.open();
    return () => {
      active.current = false;
      // A Strict Mode effect replay is synchronous. Only a real unmount releases native ownership.
      queueMicrotask(() => {
        if (!active.current) void owner.dispose();
      });
    };
  }, [owner]);
  return <EditorContext value={owner}>{children}</EditorContext>;
}
export function useEditor() {
  const model = useContext(EditorContext);
  if (!model) throw Error("editor_provider_missing");
  const state = useSyncExternalStore(
    model.subscribe,
    model.getSnapshot,
    model.getSnapshot,
  );
  return { model, state };
}
