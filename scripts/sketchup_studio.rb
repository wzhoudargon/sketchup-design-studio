# frozen_string_literal: true
# Load this file INSIDE SketchUp. Merely loading never creates geometry or files.
unless defined?(Sketchup) && defined?(UI)
  raise LoadError, '请在 SketchUp 桌面版 Ruby 控制台中 load 本文件，不要使用系统 Ruby 执行'
end
require 'sketchup.rb'
raise LoadError, '本执行器目标为 SketchUp 2022 或更新桌面版；旧版本请先做适配' if Sketchup.version.to_i < 22
require_relative 'studio/runner'
require_relative 'studio/model_guard'
require_relative 'studio/panel'
require_relative 'studio/geometry'

module SketchupDesignStudio
  class << self
    def submit(steps:, plan_id:, title: '建模生成', mode: :animated, interval: 0.12, speed: 1.0, panel: true)
      runner = Runner.new(model: Sketchup.active_model, steps: steps, plan_id: plan_id,
                          title: title, mode: mode, interval: interval, speed: speed)
      runner.preflight!
      @jobs ||= {}
      @jobs[runner.job_id] = runner
      @last_job_id = runner.job_id
      while @jobs.size > 16
        _old_id, old_job = @jobs.shift
        old_job.dispose!
      end
      show_panel(runner.job_id) if panel
      runner.start
      runner
    rescue StandardError
      @jobs.delete(runner.job_id) if @jobs && runner && runner.state == :idle
      raise
    end

    def job(job_id = nil)
      result = (@jobs || {})[job_id || @last_job_id]
      raise ArgumentError, '找不到本次 SketchUp 会话中的任务；请使用 submit 返回的 job_id' unless result
      result
    end

    def status(job_id = nil, detail: :full)
      case detail
      when :full then job(job_id).snapshot
      when :brief then job(job_id).brief_snapshot
      else raise ArgumentError, 'detail 只能为 :full 或 :brief'
      end
    end

    def status_json(job_id = nil, detail: :full)
      JSON.generate(status(job_id, detail: detail))
    end

    def status_brief(job_id = nil)
      status(job_id, detail: :brief)
    end

    def status_brief_json(job_id = nil)
      status_json(job_id, detail: :brief)
    end

    # Call before a separate save/export step. This is an execution-completion
    # gate, not a claim that dimensions or topology have passed visual acceptance.
    def assert_completed!(job_id = nil)
      job(job_id).assert_completed!
    end

    # Explicit allowlist; suitable for an existing authorized Ruby workbench.
    def control(job_id, command, value = nil, detail: :full)
      raise ArgumentError, 'detail 只能为 :full 或 :brief' unless [:full, :brief].include?(detail)
      runner = job(job_id)
      case command.to_s
      when 'pause' then runner.pause
      when 'resume' then runner.resume
      when 'step' then runner.step_once
      when 'cancel' then runner.cancel
      when 'speed' then runner.speed = value
      when 'mode' then runner.mode = value
      else raise ArgumentError, '未知控制命令'
      end
      status(job_id, detail: detail)
    end

    def show_panel(job_id = nil)
      runner = job(job_id)
      if @panel && !@panel.closed? && @panel.runner.equal?(runner)
        return @panel.show
      end
      @panel.close if @panel && !@panel.closed?
      @panel = Panel.new(runner)
      @panel.show
    end

    def demo(mode: :animated)
      require_relative '../examples/animated_pavilion'
      Examples::Pavilion.run(mode: mode)
    end
  end
end
