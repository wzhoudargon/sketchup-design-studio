# frozen_string_literal: true
# Main-thread executor for trusted SketchUp Ruby steps. Not a Ruby sandbox.
require 'json'
require 'securerandom'
require 'time'

module SketchupDesignStudio
  VERSION = '1.2.1' unless const_defined?(:VERSION)
  DICTIONARY = 'sketchup_design_studio' unless const_defined?(:DICTIONARY)
  class BusyError < StandardError; end
  class ContextError < StandardError; end
  class DuplicatePlanError < StandardError; end

  class << self
    attr_accessor :current_runner
  end

  class Runner
    TERMINAL_STATES = [:completed, :cancelled, :failed].freeze
    MODES = [:animated, :fast].freeze
    FAST_BATCH_LIMIT = 32
    FAST_BUDGET_SECONDS = 0.012
    attr_reader :state, :root, :job_id, :plan_id, :model, :mode

    def initialize(model:, steps:, plan_id:, title: '建模生成', mode: :animated,
                   interval: 0.12, speed: 1.0)
      @model = model
      @plan_id = clean_text(plan_id, 'plan_id', 160)
      @title = clean_text(title, 'title', 160)
      raise ArgumentError, 'steps 必须是非空数组' unless steps.is_a?(Array) && !steps.empty?
      @steps = steps.each_with_index.map do |step, index|
        raise ArgumentError, '每步必须是 Hash' unless step.is_a?(Hash)
        action = step.fetch(:action)
        raise ArgumentError, 'action 必须可调用' unless action.respond_to?(:call)
        {
          id: clean_text(step.fetch(:id, "step_#{index + 1}"), 'step id', 160),
          label: clean_text(step.fetch(:label), 'step label', 240),
          phase: clean_text(step.fetch(:phase, '建模'), 'phase', 120),
          action: action
        }.freeze
      end.freeze
      raise ArgumentError, '步骤 id 不可重复' unless @steps.map { |s| s[:id] }.uniq.length == @steps.length
      @interval = Float(interval)
      raise ArgumentError, 'interval 必须在 0.02–10 秒之间' unless @interval.finite? && @interval.between?(0.02, 10.0)
      @mode = valid_mode(mode)
      @speed = valid_speed(speed)
      @job_id = SecureRandom.uuid.freeze
      @state, @completed, @generation, @revision = :idle, 0, 0, 0
      @notification_timer, @monitor_released = nil, false
      @root, @timer, @error, @guard = nil, nil, nil, nil
      @invalid_reason, @started_at, @finished_at = nil, nil, nil
      @in_step, @owns_operation = false, false
      @listeners, @data, @warnings, @history = [], { job_id: @job_id, plan_id: @plan_id }, [], []
      @last_step_ms = 0.0
      @phase_totals, @phase_completed = {}, Hash.new(0)
      @steps.each { |step| @phase_totals[step[:phase]] = @phase_totals.fetch(step[:phase], 0) + 1 }
    end

    def terminal?
      TERMINAL_STATES.include?(@state)
    end

    def owns_operation?
      @owns_operation
    end

    def on_change(&block)
      raise ArgumentError, '需要状态回调' unless block
      @listeners << block
      block
    end

    def remove_listener(listener)
      @listeners.delete(listener)
    end

    # Observer callbacks only set this flag; never modify geometry in observers.
    def invalidate_context!(reason)
      return unless [:running, :paused, :completed].include?(@state)
      return if @invalid_reason
      @invalid_reason = reason.to_s.dup.freeze
      @revision += 1
      # Observers only flag state and defer UI delivery; never edit geometry here.
      queue_notification
      nil
    end

    def snapshot
      completion_reason = completion_issue
      next_step = terminal? ? nil : @steps[@completed]
      phase_counts = @phase_totals.map do |name, total|
        { name: name, total: total, completed: @phase_completed[name] }
      end
      # Never share mutable strings/hashes with UI listeners or workbench callers.
      JSON.parse(JSON.generate({
        version: VERSION, job_id: @job_id, plan_id: @plan_id, title: @title,
        state: @state.to_s, mode: @mode.to_s, completed: @completed,
        total: @steps.length, percent: (@completed * 100.0 / @steps.length).round(1),
        next_step: next_step && next_step[:label], phase: next_step && next_step[:phase],
        phases: phase_counts, speed: @speed, error: @error,
        warnings: @warnings, recent_steps: @history, last_step_ms: @last_step_ms,
        started_at: @started_at, finished_at: @finished_at,
        revision: @revision, completion_valid: completion_reason.nil?,
        completion_reason: completion_reason,
        geometry_completed: completion_reason.nil?,
        file_saved_by_runner: false, # The runner never saves or exports a model.
        context_invalidated: !@invalid_reason.nil?
      }), symbolize_names: true)
    end

    # Compact tool result. Does not construct phase arrays or copy step history.
    def brief_snapshot
      next_step = terminal? ? nil : @steps[@completed]
      issue = completion_issue
      error = @error && {
        type: @error[:type], step_id: @error[:step_id],
        message: @error[:message].to_s[0, 320]
      }
      JSON.parse(JSON.generate({
        version: VERSION, job_id: @job_id, state: @state.to_s,
        revision: @revision, completed: @completed, total: @steps.length,
        phase: next_step && next_step[:phase], completion_valid: issue.nil?,
        completion_reason: issue && issue[0, 320], error: error,
        warning_count: @warnings.length, file_saved_by_runner: false
      }), symbolize_names: true)
    end

    # Read-only execution proof, NOT topology, dimension or visual validation.
    def completion_issue
      return '生成步骤尚未全部成功提交' unless @state == :completed
      return @invalid_reason if @invalid_reason
      return '完成后监视已释放；旧任务不能再作为自动交付依据' if @monitor_released || !@guard
      return '任务模型已关闭或活动模型已切换' unless @model && @model.valid? && Sketchup.active_model.equal?(@model)
      return '请退出群组 / 组件编辑后再检查交付状态' unless @model.active_path.nil? || @model.active_path.empty?
      return '生成任务组已失效、被锁定或隐藏' unless @root && @root.valid? && !@root.locked? && !@root.hidden?
      expected = {
        'job_id' => @job_id, 'plan_id' => @plan_id, 'runtime_version' => VERSION,
        'completed_steps' => @steps.length, 'total_steps' => @steps.length,
        'last_step_id' => @steps.last[:id]
      }
      mismatch = expected.keys.find { |key| @root.get_attribute(DICTIONARY, key) != expected[key] }
      mismatch ? "模型检查点不匹配：#{mismatch}；可能已撤销或被改动，请重新验收" : nil
    rescue StandardError => e
      "无法核实完成状态：#{e.class.name}；请检查模型"
    end

    def assert_completed!
      assert_main_thread!
      issue = completion_issue
      raise ContextError, issue if issue
      @model
    end

    # Completed jobs retain a lightweight observer. Registry eviction releases it.
    def dispose!
      assert_main_thread!
      raise BusyError, '运行或暂停的任务不可释放；请先停止' unless terminal?
      @monitor_released = true
      release_guard
      timer, @notification_timer = @notification_timer, nil
      begin
        UI.stop_timer(timer) if timer
      rescue StandardError => e
        warning("释放通知计时器失败；过期回调已被停用：#{e.message}")
      ensure
        @listeners.clear
      end
      nil
    end

    # Read-only preflight, also called by start. Submit outside any existing operation.
    def preflight!
      assert_main_thread!
      raise BusyError, '此任务已经启动；不要重复 start' unless @state == :idle
      other = SketchupDesignStudio.current_runner
      if other && !other.terminal?
        raise BusyError, '另一个生成任务正在运行或暂停；请先继续或停止该任务'
      end
      validate_context!
      duplicate = @model.entities.any? do |entity|
        entity.respond_to?(:get_attribute) &&
          entity.get_attribute(DICTIONARY, 'plan_id') == @plan_id
      end
      raise DuplicatePlanError, '当前模型已有同一 plan_id 的生成结果；请检查后局部修改，或显式使用新版本 id 创建变体' if duplicate
      true
    end

    def start
      preflight!
      SketchupDesignStudio.current_runner = self
      @state, @started_at = :running, Time.now.utc.iso8601
      begin
        if defined?(ModelGuard)
          @guard = ModelGuard.new(self)
          raise ContextError, '无法注册模型保护观察器' unless @model.add_observer(@guard)
        end
        publish
        schedule if @state == :running
      rescue StandardError => e
        fail_job(e)
      end
      self
    end

    def pause
      assert_main_thread!
      return false unless @state == :running && !@in_step
      clear_timer
      @state = :paused
      publish
      true
    end

    def resume
      assert_main_thread!
      return false unless @state == :paused && !@in_step
      begin
        validate_context!
        @state = :running
        publish
        schedule if @state == :running
        true
      rescue StandardError => e
        fail_job(e)
        false
      end
    end

    def step_once
      assert_main_thread!
      return false unless @state == :paused && !@in_step
      tick(single_step: true)
      true
    end

    # Cancellation only stops future work. Committed geometry is deliberately kept.
    def cancel
      assert_main_thread!
      return false unless [:running, :paused].include?(@state) && !@in_step
      finish(:cancelled)
      true
    end

    def speed=(value)
      assert_main_thread!
      raise BusyError, '不能在步骤内部改变播放速度' if @in_step
      @speed = valid_speed(value)
      reschedule
      @speed
    end

    def mode=(value)
      assert_main_thread!
      raise BusyError, '不能在步骤内部切换模式' if @in_step
      @mode = valid_mode(value)
      reschedule
      @mode
    end

    def write_report(path)
      assert_main_thread!
      # Exclusive creation: never silently overwrite an existing file.
      File.open(File.expand_path(path), 'wx', encoding: 'UTF-8') do |file|
        file.write(JSON.pretty_generate(snapshot))
        file.write("\n")
      end
      File.expand_path(path)
    end

    private

    def clean_text(value, field, limit)
      raise ArgumentError, "#{field} 必须是非空字符串（最多 #{limit} 字符）" unless value.is_a?(String) && !value.strip.empty? && value.length <= limit
      value.strip.dup.freeze
    end

    def valid_mode(value)
      symbol = value.respond_to?(:to_sym) ? value.to_sym : nil
      raise ArgumentError, 'mode 只能是 animated 或 fast' unless MODES.include?(symbol)
      symbol
    end

    def valid_speed(value)
      speed = Float(value)
      raise ArgumentError, 'speed 必须在 0.25–4 倍之间' unless speed.finite? && speed.between?(0.25, 4.0)
      speed
    end

    def assert_main_thread!
      raise ThreadError, '必须在 SketchUp 的主线程 / Ruby 控制台调用' unless Thread.current == Thread.main
    end

    def validate_context!
      raise ContextError, @invalid_reason if @invalid_reason
      raise ContextError, '活动模型已切换；已停止，未向新模型写入' unless Sketchup.active_model.equal?(@model)
      raise ContextError, '原模型已关闭或失效' unless @model && @model.valid?
      raise ContextError, '请先退出群组 / 组件编辑，回到模型最外层' unless @model.active_path.nil? || @model.active_path.empty?
      raise ContextError, '请将活动标签切换为 Untagged / Layer0，再开始生成' unless @model.active_layer == @model.layers[0]
      return unless @root
      raise ContextError, '生成任务组被删除、撤销或失效' unless @root.valid?
      raise ContextError, '生成任务组已被锁定' if @root.locked?
      raise ContextError, '生成任务组已被隐藏' if @root.hidden?
    end

    def clear_timer
      @generation += 1
      timer, @timer = @timer, nil
      UI.stop_timer(timer) if timer
    rescue StandardError => e
      warning("停止计时器失败；过期回调仍由序号拦截：#{e.message}")
    end

    def reschedule
      clear_timer
      publish
      schedule if @state == :running
    rescue StandardError => e
      fail_job(e)
    end

    def schedule
      return unless @state == :running && @timer.nil?
      @generation += 1
      token = @generation
      delay = @mode == :fast ? 0.02 : [@interval / @speed, 0.02].max
      @timer = UI.start_timer(delay, false) do
        next unless @state == :running && token == @generation && !@in_step
        # Retire before running Ruby. Protects against reentry/modal timer quirks.
        clear_timer
        tick
      end
    rescue StandardError => e
      fail_job(e)
    end

    def tick(single_step: false)
      return if @in_step || terminal?
      return unless @state == :running || (single_step && @state == :paused)
      started = monotonic
      limit = (single_step || @mode == :animated) ? 1 : FAST_BATCH_LIMIT
      limit.times do
        break unless execute_one
        break if @completed >= @steps.length
        break if monotonic - started >= FAST_BUDGET_SECONDS
      end
      return if terminal?
      if @completed == @steps.length
        finish(:completed)
      else
        publish
        schedule if @state == :running
      end
    rescue StandardError => e
      fail_job(e)
    end

    def execute_one
      @in_step = true
      operation_open = false
      step = @steps.fetch(@completed)
      started = monotonic
      begin
        validate_context!
        @owns_operation = true
        raise 'SketchUp 无法开始操作' unless @model.start_operation("#{@title} · #{step[:label]}", true)
        operation_open = true
        unless @root
          @root = @model.entities.add_group
          @root.name = "生成任务 · #{@title} · #{@job_id[0, 8]}"
          @root.layer = @model.layers[0]
          @root.set_attribute(DICTIONARY, 'plan_id', @plan_id)
          @root.set_attribute(DICTIONARY, 'job_id', @job_id)
          @root.set_attribute(DICTIONARY, 'runtime_version', VERSION)
        end
        step[:action].call(@root.entities, @data)
        validate_context!
        # Persist a checkpoint in the same transaction as the actual geometry.
        @root.set_attribute(DICTIONARY, 'completed_steps', @completed + 1)
        @root.set_attribute(DICTIONARY, 'total_steps', @steps.length)
        @root.set_attribute(DICTIONARY, 'last_step_id', step[:id])
        raise 'SketchUp 无法提交操作' unless @model.commit_operation
        operation_open = false
        @completed += 1
        @phase_completed[step[:phase]] += 1
        @last_step_ms = ((monotonic - started) * 1000).round(2)
        @history << { id: step[:id], label: step[:label], phase: step[:phase], milliseconds: @last_step_ms }
        @history.shift while @history.length > 20
        warning('存在超过 200ms 的步骤；暂停需等该步骤结束，建议进一步拆分复杂几何') if @last_step_ms > 200
      rescue StandardError => e
        if operation_open
          begin
            @model.abort_operation
          rescue StandardError => abort_error
            warning("当前步骤回滚失败，需要人工检查：#{abort_error.message}")
          end
        end
        @root = nil if @root && !@root.valid?
        # Release ownership before notifying consumers about failure.
        @owns_operation = false
        @in_step = false
        fail_job(e, step)
        return false
      ensure
        @owns_operation = false
        @in_step = false
      end
      begin
        @model.active_view.invalidate
      rescue StandardError => e
        # Geometry has committed: a drawing failure must not pretend it rolled back.
        warning("几何已提交，但视口刷新失败：#{e.message}")
      end
      true
    end

    def fail_job(error, step = @steps[@completed])
      return if terminal?
      @error = {
        type: error.class.name, message: error.message,
        step_id: step && step[:id], step_label: step && step[:label],
        phase: step && step[:phase]
      }
      finish(:failed)
    end

    def finish(state)
      return if terminal?
      clear_timer
      @state, @finished_at = state, Time.now.utc.iso8601
      # Terminal jobs cannot resume; release action closures and temporary data.
      @data.clear
      @steps = @steps.map { |step| step.reject { |key, _value| key == :action }.freeze }.freeze
      # Retain successful-job monitors for later commits / undo / redo.
      release_guard unless state == :completed
      SketchupDesignStudio.current_runner = nil if SketchupDesignStudio.current_runner.equal?(self)
      publish
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def warning(message)
      return if @warnings.include?(message)
      @warnings << message.to_s
      @warnings.shift while @warnings.length > 10
      warn("[SketchupDesignStudio] #{message}")
    end

    def release_guard
      return unless @guard
      begin
        @model.remove_observer(@guard)
      rescue StandardError => e
        warning("释放观察器失败：#{e.message}")
      ensure
        @guard = nil
      end
    end

    def queue_notification
      return if @notification_timer || @listeners.empty?
      @notification_timer = UI.start_timer(0.02, false) do
        timer, @notification_timer = @notification_timer, nil
        next unless timer
        begin
          UI.stop_timer(timer)
        rescue StandardError => e
          warning("通知计时器停止失败；重复回调仍会被忽略：#{e.message}")
        end
        notify_listeners unless @monitor_released
      end
    rescue StandardError => e
      warning("状态通知失败；后续查询仍会返回失效状态：#{e.message}")
    end

    def publish
      @revision += 1
      notify_listeners
    end

    def notify_listeners
      @listeners.dup.each do |callback|
        begin
          callback.call(snapshot)
        rescue StandardError => e
          warning("状态接收端出错（不影响已提交几何）：#{e.message}")
        end
      end
    end
  end
end
