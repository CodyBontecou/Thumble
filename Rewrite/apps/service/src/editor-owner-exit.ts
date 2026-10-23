import type { ChildProcessWithoutNullStreams } from "node:child_process";
/** Exit event/state, never stdin EOF, kill issuance, or elapsed time, proves death.
 * Failure keeps the caller's write slot closed and retained. */
export function confirmEditorWriterExit(
  child: ChildProcessWithoutNullStreams,
): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null)
    return Promise.resolve();
  return new Promise((resolve, reject) => {
    const finish = () => {
      clearTimeout(kill);
      clearTimeout(limit);
      child.off("exit", exited);
    };
    const exited = () => {
      finish();
      resolve();
    };
    const kill = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        /* still require exit */
      }
    }, 2000);
    const limit = setTimeout(() => {
      finish();
      reject(new Error("editor_writer_exit_unconfirmed"));
    }, 3000);
    child.once("exit", exited);
    if (child.exitCode !== null || child.signalCode !== null) exited();
  });
}
