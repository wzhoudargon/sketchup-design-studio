# frozen_string_literal: true
# Copy into the project; replace this require with the installed Skill's ABSOLUTE
# path when moving the file. Loading only defines functions, not geometry.
require_relative '../scripts/sketchup_studio'

module StudioExampleTask
  module_function

  def submit(mode: :animated)
    # Keep this id stable across accidental retries; change it deliberately only
    # for a new variant. Existing objects are never automatically deleted.
    plan_id = 'example.room.v1'
    tasks = [
      {id: 'floor', phase: '地面', label: '创建楼板', action: lambda { |entities, _data|
        SketchupDesignStudio::Geometry.box_mm(entities, id: 'floor', name: '楼板 · 展室 · 01',
                                             origin: [0, 0, 0], size: [6000, 4000, 200])
      }}
    ]
    # A single continuous wall whose top face rises; NOT stacked wall segments.
    12.times do |level|
      height = (level + 1) * 250
      tasks << {id: "wall.height.#{height}", phase: '墙体', label: "北墙升至 #{height}mm",
                action: lambda { |entities, data|
        if level.zero?
          data[:wall] = SketchupDesignStudio::Geometry.box_mm(entities, id: 'wall.north', name: '墙 · 北界面 · 01',
                                                            origin: [0, 3800, 200], size: [6000, 200, height])
        else
          SketchupDesignStudio::Geometry.grow_to_mm(data.fetch(:wall), height)
        end
      }}
    end
    SketchupDesignStudio.submit(steps: tasks, plan_id: plan_id, title: '展室 · 墙体生成示例', mode: mode)
  end
end

# After load, execute: job = StudioExampleTask.submit
# Then (in a SEPARATE workbench/Ruby call): SketchupDesignStudio.status_brief_json(job.job_id)
# DO NOT busy-wait, sleep, auto-save, or assume submit returning means completion.
