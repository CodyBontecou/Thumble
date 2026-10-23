// Real configuration owner; suppress exactly its committed import reply, then
// exit before delivery so the client cannot know whether the transaction committed.
import { runConfigurationOwner } from "../../apps/service/src/configuration-owner-process.ts";
const originalWrite = process.stdout.write.bind(process.stdout);
type Callback = (error?: Error | null) => void;
function write(buffer: string | Uint8Array, callback?: Callback): boolean;
function write(
  buffer: string | Uint8Array,
  encoding?: BufferEncoding,
  callback?: Callback,
): boolean;
function write(
  buffer: string | Uint8Array,
  encodingOrCallback?: BufferEncoding | Callback,
  callback?: Callback,
): boolean {
  if (typeof buffer === "string") {
    const frame = JSON.parse(buffer);
    if (frame.result?.kind === "import-committed") {
      setImmediate(() => process.exit(0));
      return true;
    }
  }
  return typeof encodingOrCallback === "function"
    ? originalWrite(buffer, encodingOrCallback)
    : originalWrite(buffer, encodingOrCallback, callback);
}
process.stdout.write = write;
const directory = process.argv[process.argv.indexOf("--runtime-dir") + 1],
  receiver = process.argv[process.argv.indexOf("--receiver") + 1];
if (!directory || !receiver) throw new Error("test_owner_arguments_invalid");
await runConfigurationOwner(directory, receiver);
