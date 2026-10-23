// Shell fallback for agents whose MCP connection has not been refreshed yet.
// Usage: node tools/profile.mjs TOOL_NAME < arguments.json
import { ProfileStore } from '../packages/profile-tools/src/store.js';
import { callProfileTool } from '../packages/profile-tools/src/tools.js';
try {
  let input = '';
  if (!process.stdin.isTTY) for await (const chunk of process.stdin) { input += chunk; if (Buffer.byteLength(input) > 1024 * 1024) throw Error('Arguments exceed 1 MiB'); }
  const result = await callProfileTool(new ProfileStore(), process.argv[2], input.trim() ? JSON.parse(input) : {});
  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
} catch (error) { process.stderr.write(error.message + '\n'); process.exitCode = 1; }
