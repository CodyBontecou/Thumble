import { basename } from "node:path";
// Compiled synthetic adversarial child; never an OS input adapter.
const name = basename(process.execPath);
if (name.includes("oversize")) console.log("x".repeat(4097));
else if (name.includes("stderr")) {
  console.error("synthetic-private-provider-detail");
  process.exitCode = 1;
} else if (name.includes("timeout")) setInterval(() => {}, 1000);
else console.log('{"version":1,"version":1}');
