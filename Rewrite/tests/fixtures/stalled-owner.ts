import { NativeReceiver } from "../../apps/service/src/native-receiver.ts";
import { neutralGamepadState } from "@thumble/contracts";
const [executable, directory, log] = process.argv.slice(2);
if (!executable || !directory || !log)
  throw new Error("missing_fixture_arguments");
const receiver = new NativeReceiver(executable, directory, log);
await receiver.ready;
await receiver.request({
  command: "activate",
  generation: "1",
  revision: "1",
  profileId: "fixture",
  sessionId: "test-session",
  leaseMs: 500,
  inputTtlMs: 400,
});
await receiver.request({
  command: "sample",
  generation: "1",
  sessionId: "test-session",
  sequence: "1",
  state: {
    ...neutralGamepadState(),
    buttons: ["south"],
    leftTrigger: 1,
    rightTrigger: 1,
  },
});
const end = performance.now() + 900;
while (performance.now() < end) {
  /* Deliberate JS stall; native safety must keep running. */
}
const status = await receiver.request({ command: "status" });
console.log(JSON.stringify(status));
await receiver.request({ command: "shutdown" });
receiver.disconnect();
