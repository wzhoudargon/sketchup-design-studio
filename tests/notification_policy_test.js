'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {createNotificationPolicy} = require('../examples/workbench_notification_policy');
const status = (overrides = {}) => ({job_id: 'job-a', revision: 1, state: 'running', completion_valid: false, ...overrides});
test('70 local progress updates and one completion notification', () => {
  const notify = createNotificationPolicy(); let count = 0;
  for (let i = 0; i < 70; i++) count += Number(notify(status({revision: i, completed: i})));
  count += Number(notify(status({revision: 70, state: 'completed', completion_valid: true})));
  assert.equal(count, 1);
});
test('unchanged terminal state is deduplicated', () => {
  const notify = createNotificationPolicy();
  assert.equal(notify(status({state: 'completed', completion_valid: true})), true);
  assert.equal(notify(status({state: 'completed', revision: 2, completion_valid: true})), false);
});
test('invalidated completion notifies even with unchanged revision', () => {
  const notify = createNotificationPolicy();
  notify(status({state: 'completed', completion_valid: true}));
  assert.equal(notify(status({state: 'completed', completion_valid: false, completion_reason: 'undo'})), true);
});
test('pause resume pause notifies each new pause', () => {
  const notify = createNotificationPolicy();
  assert.equal(notify(status({state: 'paused'})), true);
  assert.equal(notify(status({state: 'paused'})), false);
  assert.equal(notify(status({state: 'running', revision: 2})), false);
  assert.equal(notify(status({state: 'paused', revision: 3})), true);
});
test('out of order status is ignored', () => {
  const notify = createNotificationPolicy();
  notify(status({state: 'completed', revision: 20, completion_valid: true}));
  assert.equal(notify(status({state: 'failed', revision: 19})), false);
});
test('independent job identities and changed errors', () => {
  const notify = createNotificationPolicy();
  assert.equal(notify(status({state: 'failed', error: {message: 'a'}})), true);
  assert.equal(notify(status({state: 'failed', error: {message: 'b'}})), true);
  assert.equal(notify(status({job_id: 'job-b', state: 'failed'})), true);
});
test('malformed status is rejected', () => {
  const notify = createNotificationPolicy();
  for (const value of [null, {}, status({state: 'done'}), status({revision: -1}), status({state: 'completed', completion_valid: undefined})]) {
    assert.throws(() => notify(value), TypeError);
  }
  assert.throws(() => createNotificationPolicy(0), TypeError);
});
test('bounded memory evicts oldest job', () => {
  const notify = createNotificationPolicy(1);
  assert.equal(notify(status({state: 'paused'})), true);
  notify(status({job_id: 'job-b'}));
  assert.equal(notify(status({state: 'paused'})), true);
});
