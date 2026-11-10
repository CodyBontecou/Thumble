import assert from 'node:assert/strict';
import { sameSource } from './common.mjs';

// Every value on `actual` is re-read from disk or Git at the upload boundary.
export function verifyManifest(manifest, actual) {
  assert.equal(manifest.schemaVersion, 1, 'Unsupported release manifest.');
  sameSource(manifest.source, actual.source);
  assert.equal(manifest.artifact.sha256, actual.ipaSha256, 'IPA changed after validation.');
  assert.deepEqual(manifest.app, actual.app, 'App metadata or payload changed.');
  assert.equal(actual.app.platform, 'iPhoneOS', 'The release artifact must target iPhoneOS.');
  assert.equal(actual.app.sourceCommit, actual.source.commit, 'IPA belongs to another source commit.');
  assert.equal(actual.app.sourceTree, actual.source.tree, 'IPA belongs to another source tree.');
  assert.equal(actual.app.lockSha256, actual.lockSha256, 'IPA dependency lock differs.');
  assert.equal(manifest.check.sha256, actual.checkSha256, 'Source check log changed.');
  assert.equal(manifest.smokeSha256, actual.smokeSha256, 'Smoke receipt changed.');
  const smoke = actual.smoke;
  sameSource(manifest.source, smoke.source);
  assert.equal(smoke.configuration, 'Release');
  assert.equal(smoke.platform, 'ios-simulator');
  assert.equal(smoke.productionBundle, true, 'The production payload was not tested.');
  assert.equal(smoke.app.bundleSha256, actual.app.bundleSha256, 'Tested JavaScript differs from the IPA.');
  assert.equal(smoke.app.assetsSha256, actual.app.assetsSha256, 'Tested assets differ from the IPA.');
  assert.equal(smoke.testSha256, actual.testSha256, 'Smoke test changed after validation.');
  assert.equal(smoke.reports.length, 2, 'Two clean-install launch passes are required.');
  assert.deepEqual(smoke.reports.map(report => report.sha256), actual.reportHashes, 'Launch reports changed.');
}
