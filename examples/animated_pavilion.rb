# frozen_string_literal: true
# Loading only defines the demo. Invoke SketchupDesignStudio.demo to build it.
require_relative '../scripts/sketchup_studio'

module SketchupDesignStudio
  module Examples
    module Pavilion
      module_function

      def steps
        tasks = []
        tasks << {
          id: 'slab', phase: '地台', label: '铺设地台 · 10000×8000mm',
          action: lambda do |entities, data|
            colors = {stone: [202, 205, 194], wood: [167, 115, 74], dark: [75, 90, 82]}
            names = {stone: ['石材', '地台', '浅灰'], wood: ['木材', '亭架', '暖棕'], dark: ['涂层', '梁架', '深灰绿']}
            data[:materials] = colors.each_with_object({}) do |(key, rgb), result|
              # Unique new materials. Never modify an existing project's palette.
              kind, zone, tone = names.fetch(key)
              material = entities.model.materials.add("#{kind} · 演示#{zone}#{data.fetch(:job_id)[0, 8]} · #{tone} · 01")
              material.color = Sketchup::Color.new(*rgb)
              result[key] = material
            end
            Geometry.box_mm(entities, id: 'slab', name: '地台 · 庭院 · 01',
                            origin: [0, 0, 0], size: [10000, 8000, 200], material: data[:materials][:stone])
          end
        }
        positions = [[1000, 1000], [8600, 1000], [1000, 6600], [8600, 6600]]
        12.times do |level|
          positions.each_with_index do |xy, index|
            id = "column.#{index + 1}"
            height = (level + 1) * 250
            tasks << {
              id: "#{id}.height.#{height}", phase: '立柱', label: "立柱 #{index + 1} · 生长至 #{height}mm",
              action: lambda do |entities, data|
                if level.zero?
                  data[id] = Geometry.box_mm(entities, id: id, name: "柱 · 庭院 · #{format('%02d', index + 1)}",
                                             origin: [xy[0], xy[1], 200], size: [400, 400, height], material: data[:materials][:wood])
                else
                  Geometry.grow_to_mm(data.fetch(id), height)
                end
              end
            }
          end
        end
        beams = [
          [[1000, 1000, 3200], [8000, 400, 300]], [[1000, 6600, 3200], [8000, 400, 300]],
          [[1000, 1400, 3200], [400, 5200, 300]], [[8600, 1400, 3200], [400, 5200, 300]]
        ]
        beams.each_with_index do |(origin, size), index|
          tasks << {
            id: "beam.#{index + 1}", phase: '梁架', label: "安装边梁 #{index + 1}",
            action: lambda do |entities, data|
              Geometry.box_mm(entities, id: "beam.#{index + 1}", name: "梁 · 亭架 · #{format('%02d', index + 1)}",
                              origin: origin, size: size, material: data[:materials][:dark])
            end
          }
        end
        15.times do |index|
          tasks << {
            id: "roof.#{index + 1}", phase: '顶棚', label: "铺设顶棚格栅 #{index + 1} / 15",
            action: lambda do |entities, data|
              Geometry.box_mm(entities, id: "roof.#{index + 1}", name: "格栅 · 顶棚 · #{format('%02d', index + 1)}",
                              origin: [500 + 620 * index, 500, 3500], size: [320, 7000, 180], material: data[:materials][:wood])
            end
          }
        end
        [2200, 6000].each_with_index do |x, index|
          tasks << {
            id: "bench.#{index + 1}", phase: '细节', label: "放置坐凳 #{index + 1}",
            action: lambda do |entities, data|
              Geometry.box_mm(entities, id: "bench.#{index + 1}", name: "坐凳 · 庭院 · #{format('%02d', index + 1)}",
                              origin: [x, 5500, 200], size: [1800, 600, 450], material: data[:materials][:stone])
            end
          }
        end
        tasks
      end

      def run(mode: :animated)
        model = Sketchup.active_model
        raise ContextError, '演示仅允许在空白模型中运行，请另建测试模型（含默认人物时也需先清除）' unless model.entities.length.zero?
        runner = SketchupDesignStudio.submit(steps: steps, plan_id: 'demo.pavilion.v1', title: '庭院亭架 · 生长演示', mode: mode)
        # Only the explicit empty-model demo changes the camera, exactly once.
        if runner.state == :running
          model.active_view.camera = Sketchup::Camera.new(
            [15500.mm, -16000.mm, 12500.mm], [5000.mm, 4000.mm, 1600.mm], [0, 0, 1]
          )
        end
        runner
      end
    end
  end
end
