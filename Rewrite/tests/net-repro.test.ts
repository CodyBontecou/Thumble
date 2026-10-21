import { test, expect } from "bun:test";
import { createServer, createConnection } from "node:net";
test("Windows loopback close diagnostic", async () => {
  const server = createServer(socket => {
    socket.on("data", () => socket.end("reply\n"));
    socket.on("error", () => {});
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("bind_failed");
  try {
    for (let n = 0; n < 30; n++) {
      console.error(`[DEBUG-m2-net] request ${n}`);
      const reply = await new Promise<string>((resolve, reject) => {
        const socket = createConnection({host: "127.0.0.1", port: address.port});
        socket.on("error", reject);
        socket.on("connect", () => socket.write("request\n"));
        socket.on("data", data => { socket.destroy(); resolve(data.toString()); });
      });
      expect(reply).toBe("reply\n");
    }
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
  }
});
