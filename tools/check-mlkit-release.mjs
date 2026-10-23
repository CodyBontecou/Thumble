// Release regression: ML Kit discovers these classes through manifest metadata.
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const mapping = readFileSync(new URL('../apps/mobile/android/app/build/outputs/mapping/release/mapping.txt', import.meta.url),'utf8');
for (const name of ['com.google.mlkit.common.internal.CommonComponentRegistrar','com.google.mlkit.vision.barcode.internal.BarcodeRegistrar','com.google.mlkit.vision.common.internal.VisionCommonRegistrar']) {
  const start = mapping.indexOf(`${name} -> ${name}:`);
  assert(start >= 0, `${name} must retain its manifest-discovered class name`);
  const block = mapping.slice(start).split(/\n(?=[^\s#][^\n]* -> [^\n]+:)/)[0];
  assert(block.includes('void <init>()'), `${name} lost its reflectively invoked no-argument constructor`);
}
console.log('PASS all three manifest-discovered ML Kit registrar constructors survive Release shrinking');
