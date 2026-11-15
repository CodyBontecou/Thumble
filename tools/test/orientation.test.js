import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createOrientationController } from '../../apps/mobile/src/orientation-core.js';

test('a returning controller wins over queued setup orientation requests', async () => {
  const calls = []; let release;
  const controller = createOrientationController(value => {
    calls.push(value);
    return calls.length === 1 ? new Promise(resolve => { release = resolve; }) : Promise.resolve();
  });
  const first = controller.request(true);
  await Promise.resolve(); await Promise.resolve();
  controller.request(false);
  const returned = controller.request(true);
  release(); await first; await returned;
  assert.deepEqual(calls, [true, true]);
});

test('a refused native lock does not prevent later navigation recovery', async () => {
  let calls = 0;
  const controller = createOrientationController(async () => { if (++calls === 1) throw Error('Window is resizable'); });
  await assert.rejects(controller.request(true));
  await controller.request(false);
  await controller.request(true);
  assert.equal(calls, 3);
});
