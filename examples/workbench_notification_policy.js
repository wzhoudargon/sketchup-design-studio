'use strict';
// Local workbench policy only: no transport, polling scheduler or LLM calls.
function createNotificationPolicy(limit = 16) {
  if (!Number.isInteger(limit) || limit < 1) throw new TypeError('limit must be positive');
  const jobs = new Map();
  const states = new Set(['idle', 'running', 'paused', 'completed', 'cancelled', 'failed']);
  return function shouldNotify(s) {
    if (!s || typeof s.job_id !== 'string' || !s.job_id || !states.has(s.state) ||
        !Number.isInteger(s.revision) || s.revision < 0) {
      throw new TypeError('Expected brief status with job_id, state and revision');
    }
    if (s.state === 'completed' && typeof s.completion_valid !== 'boolean') {
      throw new TypeError('Completed status requires completion_valid');
    }
    const previous = jobs.get(s.job_id);
    if (previous && s.revision < previous.revision) return false;
    const signature = JSON.stringify([s.state, s.completion_valid,
      s.completion_reason || null, s.error ? [s.error.type, s.error.step_id, s.error.message] : null]);
    jobs.delete(s.job_id);
    jobs.set(s.job_id, {revision: s.revision, signature});
    while (jobs.size > limit) jobs.delete(jobs.keys().next().value);
    const attention = ['paused', 'completed', 'cancelled', 'failed'].includes(s.state);
    return attention && (!previous || signature !== previous.signature);
  };
}
module.exports = {createNotificationPolicy};
