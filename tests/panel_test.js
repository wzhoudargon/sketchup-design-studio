'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../scripts/studio/panel.js'), 'utf8');
class Element {
  constructor() { this.children = []; this.listeners = {}; this.textContent = ''; this.disabled = true; this.hidden = false; }
  get firstChild() { return this.children[0]; }
  appendChild(child) { this.children.push(child); }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  addEventListener(event, handler) { this.listeners[event] = handler; }
  fire(event) { this.listeners[event].call(this); }
}
function harness(connected = true) {
  const nodes = {}, events = {}, calls = [];
  const document = {
    getElementById(id) { return nodes[id] || (nodes[id] = new Element()); },
    createElement() { return new Element(); },
    addEventListener(event, handler) { events[event] = handler; }
  };
  const window = {};
  if (connected) {
    window.sketchup = {};
    ['ready', 'pause', 'resume', 'step', 'cancel', 'speed', 'mode', 'report'].forEach(name => {
      window.sketchup['studio_' + name] = (...args) => calls.push([name, ...args]);
    });
  }
  vm.runInNewContext(source, {document, window});
  events.DOMContentLoaded();
  return {nodes, calls, render: window.StudioPanel.render, message: window.StudioPanel.message};
}
function status(overrides = {}) {
  return {state: 'running', title: '庭院亭架', percent: 25, completed: 1, total: 4,
    next_step: '立柱长高', mode: 'animated', speed: 1, job_id: '12345678-test', phase: '立柱',
    phases: [{name: '地台', completed: 1, total: 1}, {name: '立柱', completed: 0, total: 3}],
    recent_steps: [], warnings: [], error: null, ...overrides};
}
test('handshake calls Ruby only when attached', () => {
  const h = harness(); assert.deepEqual(h.calls, [['ready']]);
});
test('offline browser never pretends to be SketchUp', () => {
  const h = harness(false); assert.match(h.nodes.message.textContent, /不能操作模型/);
});
test('running state shows actual progress and disables resume', () => {
  const h = harness(); h.render(status());
  assert.equal(h.nodes.progress.value, 25); assert.equal(h.nodes.count.textContent, '1 / 4 步');
  assert.equal(h.nodes.pause.disabled, false); assert.equal(h.nodes.resume.disabled, true);
});
test('paused state enables single step', () => {
  const h = harness(); h.render(status({state: 'paused'}));
  assert.equal(h.nodes.pause.disabled, true); assert.equal(h.nodes.single.disabled, false);
});
test('completed state disables all modeling controls', () => {
  const h = harness(); h.render(status({state: 'completed', percent: 100, completed: 4, next_step: null}));
  ['pause', 'resume', 'single', 'cancel', 'mode', 'speed'].forEach(id => assert.equal(h.nodes[id].disabled, true));
  assert.match(h.nodes.step.textContent, /另存模型/);
});
test('cancelled is not displayed as 100 percent', () => {
  const h = harness(); h.render(status({state: 'cancelled', next_step: null}));
  assert.equal(h.nodes.progress.value, 25); assert.equal(h.nodes.state.textContent, '已停止');
});
test('fast mode disables speed but allows mode switch', () => {
  const h = harness(); h.render(status({mode: 'fast'}));
  assert.equal(h.nodes.speed.disabled, true); assert.equal(h.nodes.mode.disabled, false);
});
test('labels and errors use textContent, never HTML', () => {
  const h = harness(); const attack = '<img src=x onerror=alert(1)>';
  h.render(status({title: attack, error: {step_label: '墙', message: attack}}));
  assert.equal(h.nodes.title.textContent, attack); assert.match(h.nodes.error.textContent, /<img/);
  assert.equal(h.nodes.title.children.length, 0); assert.equal(h.nodes.error.hidden, false);
  assert.doesNotMatch(source, /innerHTML|eval\(/);
});
test('phase list is replaced rather than accumulating', () => {
  const h = harness(); h.render(status()); h.render(status());
  assert.equal(h.nodes.phases.children.length, 2);
  assert.match(h.nodes.phases.children[0].className, /done/);
});
test('controls invoke allowed Ruby bridge actions', () => {
  const h = harness(); h.render(status()); h.nodes.pause.fire('click');
  h.nodes.mode.value = 'fast'; h.nodes.mode.fire('change');
  h.nodes.speed.value = '2'; h.nodes.speed.fire('change');
  assert.deepEqual(h.calls, [['ready'], ['pause'], ['mode', 'fast'], ['speed', 2]]);
});
test('progress is clamped to valid bounds', () => {
  const h = harness(); h.render(status({percent: 200})); assert.equal(h.nodes.progress.value, 100);
  h.render(status({percent: -5})); assert.equal(h.nodes.progress.value, 0);
});
test('clearing an error hides the error banner', () => {
  const h = harness(); h.render(status({error: {message: 'bad'}}));
  h.render(status()); assert.equal(h.nodes.error.hidden, true);
});
test('stale completion warns rather than suggesting immediate delivery', () => {
  const h = harness(); h.render(status({state: 'completed', next_step: null,
    completion_valid: false, completion_reason: '模型已撤销', completed: 4, total: 4, percent: 100}));
  assert.match(h.nodes.state.textContent, /待复核/);
  assert.match(h.nodes.step.textContent, /重新验收/);
  assert.match(h.nodes.warning.textContent, /撤销/);
  assert.doesNotMatch(h.nodes.step.textContent, /另存模型/);
});
