/* No eval, HTML interpolation, remote dependencies, or timers that fake progress. */
(function () {
  'use strict';
  var states = {idle: '待启动', running: '生成中', paused: '已暂停', completed: '已完成', cancelled: '已停止', failed: '生成失败'};
  function node(id) { return document.getElementById(id); }
  function text(id, value) { node(id).textContent = value == null ? '' : String(value); }
  function notice(id, value) { text(id, value); node(id).hidden = !value; }
  function bridge(name, value) {
    if (!window.sketchup || typeof window.sketchup[name] !== 'function') {
      notice('message', '此面板需要由 SketchUp 加载；浏览器预览不能操作模型。');
      return;
    }
    if (value === undefined) { window.sketchup[name](); } else { window.sketchup[name](value); }
  }
  function clear(element) { while (element.firstChild) { element.removeChild(element.firstChild); } }
  function render(s) {
    var running = s.state === 'running', paused = s.state === 'paused';
    var active = running || paused, pct = Math.max(0, Math.min(100, Number(s.percent) || 0));
    var stale = s.state === 'completed' && s.completion_valid === false;
    text('state', stale ? '完成状态待复核' : (states[s.state] || s.state)); text('title', s.title);
    text('percent', pct + '%'); text('count', s.completed + ' / ' + s.total + ' 步');
    node('progress').value = pct;
    text('step', stale ? '步骤曾执行完成，但模型现状不能再按原结果交付。请重新验收。' : s.next_step ? ('接下来 · ' + s.next_step) : (s.state === 'completed' ? '建模步骤已全部提交，请另存模型并验收。' : '没有继续执行后续步骤。'));
    node('pause').disabled = !running; node('resume').disabled = !paused;
    node('single').disabled = !paused; node('cancel').disabled = !active;
    node('mode').disabled = !active; node('speed').disabled = !active || s.mode === 'fast';
    node('mode').value = s.mode; node('speed').value = String(s.speed);
    node('report').disabled = false;
    text('job', '任务 · ' + String(s.job_id || '').slice(0, 8));
    text('hint', s.mode === 'fast' ? '快速模式批量执行同一套步骤；速度选项仅影响演示间隔。' : '可暂停、继续或单步查看。倍速改变展示间隔，不加速单步几何计算。');
    notice('error', s.error ? ((s.error.step_label || '执行器') + '：' + s.error.message) : '');
    var warnings = (s.warnings || []).slice();
    if (stale && s.completion_reason) { warnings.unshift(s.completion_reason); }
    notice('warning', warnings.join('\n'));
    clear(node('phases'));
    (s.phases || []).forEach(function (p) {
      var item = document.createElement('span');
      item.className = 'phase' + (p.completed === p.total ? ' done' : (p.name === s.phase ? ' active' : ''));
      item.textContent = p.name + ' ' + p.completed + '/' + p.total;
      node('phases').appendChild(item);
    });
    clear(node('history'));
    (s.recent_steps || []).forEach(function (step) {
      var item = document.createElement('li');
      item.textContent = step.label + ' · ' + step.milliseconds + ' ms';
      node('history').appendChild(item);
    });
  }
  window.StudioPanel = {render: render, message: function (value) { notice('message', value); }};
  document.addEventListener('DOMContentLoaded', function () {
    [['pause', 'studio_pause'], ['resume', 'studio_resume'], ['single', 'studio_step'], ['cancel', 'studio_cancel'], ['report', 'studio_report']].forEach(function (pair) {
      node(pair[0]).addEventListener('click', function () { bridge(pair[1]); });
    });
    node('speed').addEventListener('change', function () { bridge('studio_speed', Number(this.value)); });
    node('mode').addEventListener('change', function () { bridge('studio_mode', this.value); });
    bridge('studio_ready');
  });
}());
