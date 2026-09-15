# frozen_string_literal: true
# Mock JSON byte measurement; not a token, quota or cost benchmark.
require_relative '../tests/support/fakes'
require_relative '../scripts/sketchup_studio'
UI.reset
Sketchup.active_model = FakeModel.new
steps = 70.times.map do |i|
  {id: "part_#{i}", label: "创建构件 #{i}", phase: '建模',
   action: ->(entities, _data) { entities.add_group }}
end
job = SketchupDesignStudio.submit(plan_id: 'payload.example', panel: false, steps: steps)
UI.drain
full = SketchupDesignStudio.status_json(job.job_id)
brief = SketchupDesignStudio.status_brief_json(job.job_id)
puts JSON.pretty_generate({
  validation: 'mock UTF-8 bytes only; not tokens, quota, cost or native SketchUp',
  steps: 70, full_bytes: full.bytesize, brief_bytes: brief.bytesize,
  reduction_percent: ((1.0 - brief.bytesize.to_f / full.bytesize) * 100).round(1)
})
