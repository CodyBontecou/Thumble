// Run with the physical Android QR scanner open. Reads camera-service counters only.
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
const device = process.argv[2];
assert(device, 'Pass an Android device serial');
const adb = process.env.ANDROID_HOME ? `${process.env.ANDROID_HOME}/platform-tools/adb` : 'adb';
const output = execFileSync(adb,['-s',device,'shell','dumpsys','media.camera'],{encoding:'utf8',maxBuffer:16*1024*1024});
assert(output.includes('Client Package Name: com.thumble.android'), 'Open Thumble QR scanner first');
const streams = output.split(/Stream\[\d+\]: Output/).slice(1);
const analysis = streams.find(stream => /Consumer name: ImageReader[^\n]*f23/.test(stream));
assert(analysis,'No YUV image-analysis stream configured');
const frames = Number(analysis.match(/Frames produced: (\d+)/)?.[1] ?? 0);
assert(frames > 0, `Barcode analysis receives no frames (${frames}); preview alone does not establish scanning`);
console.log(`PASS barcode analysis receives camera frames (${frames})`);
