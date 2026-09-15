# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative 'support/fakes'
require_relative '../scripts/studio/runner'
require_relative '../scripts/studio/model_guard'

class RunnerTest < Minitest::Test
  Studio = SketchupDesignStudio
  Runner = Studio::Runner

  def setup
    UI.reset
    @model = Sketchup.active_model = FakeModel.new
    Studio.current_runner = nil
    @calls = []
  end

  def runner(count = 3, **options, &action)
    tasks = count.times.map do |index|
      { id: "s#{index}", label: "step #{index}", phase: index.zero? ? '地台' : '构件',
        action: action || lambda { |entities, _data|
          @calls << index
          entities.add_group.name = "part #{index}"
        } }
    end
    Runner.new(model: @model, steps: tasks, plan_id: 'test.v1', interval: 0.2, **options)
  end

  def test_start_only_accepts_without_synchronous_geometry
    job = runner.start
    assert_equal :running, job.state
    assert_empty @calls
    assert_empty @model.events
    assert_equal 1, UI.timers.length
  end

  def test_one_animated_step_per_tick
    job = runner.start
    UI.run_one
    assert_equal [0], @calls
    assert_equal 1, job.snapshot[:completed]
    assert_equal 1, @model.active_view.redraws
    refute @model.open_operation
  end

  def test_completion_reports_real_steps_and_releases_resources
    job = runner
    changes = []
    job.on_change { |s| changes << s[:state] }
    job.start
    UI.drain
    assert_equal [0, 1, 2], @calls
    assert_equal :completed, job.state
    assert_equal 100.0, job.snapshot[:percent]
    assert_nil job.snapshot[:next_step]
    assert_equal ['running', 'running', 'running', 'completed'], changes
    assert job.snapshot[:geometry_completed]
    refute job.snapshot[:file_saved_by_runner]
    assert_nil Studio.current_runner
    assert_equal 1, @model.observers.length # retained completion monitor
    assert_empty UI.timers
  end

  def test_steps_use_one_owned_root_and_persist_checkpoint
    job = runner.start
    UI.drain
    assert_equal 1, @model.entities.length
    assert_equal 3, job.root.entities.length
    assert_equal 'test.v1', job.root.get_attribute(Studio::DICTIONARY, 'plan_id')
    assert_equal 3, job.root.get_attribute(Studio::DICTIONARY, 'completed_steps')
    assert_equal 's2', job.root.get_attribute(Studio::DICTIONARY, 'last_step_id')
    assert_equal @model.layers[0], job.root.layer
  end

  def test_pause_resume
    job = runner.start
    UI.run_one
    assert job.pause
    UI.drain
    assert_equal [0], @calls
    assert job.resume
    UI.drain
    assert_equal :completed, job.state
  end

  def test_single_step_remains_paused_until_final_step
    job = runner(2).start
    job.pause
    assert job.step_once
    assert_equal :paused, job.state
    assert_equal [0], @calls
    assert_empty UI.timers
    job.step_once
    assert_equal :completed, job.state
  end

  def test_single_step_ignored_when_running
    job = runner.start
    refute job.step_once
    assert_empty @calls
  end

  def test_cancel_keeps_completed_geometry
    job = runner.start
    UI.run_one
    assert job.cancel
    UI.drain
    assert_equal :cancelled, job.state
    assert_equal 1, job.root.entities.length
    assert_equal 1, job.snapshot[:completed]
    refute job.resume
    refute job.step_once
  end

  def test_cancel_before_first_step_writes_nothing
    job = runner.start
    job.cancel
    assert_empty @model.events
    assert_equal 0, @model.entities.length
    assert_empty @model.observers
  end

  def test_paused_job_blocks_second_start
    job = runner.start
    job.pause
    assert_raises(Studio::BusyError) { runner.start }
  end

  def test_same_job_cannot_restart
    job = runner.start
    assert_raises(Studio::BusyError) { job.start }
    UI.drain
    assert_raises(Studio::BusyError) { job.start }
  end

  def test_stale_callback_after_pause_is_ignored
    job = runner.start
    stale = UI.callbacks.last
    job.pause
    job.resume
    stale.call
    assert_empty @calls
    UI.drain
    assert_equal [0, 1, 2], @calls
  end

  def test_duplicate_callback_cannot_duplicate_geometry
    runner.start
    callback = UI.callbacks.last
    callback.call
    callback.call
    assert_equal [0], @calls
    UI.drain
    assert_equal [0, 1, 2], @calls
  end

  def test_speed_replaces_single_timer
    job = runner.start
    job.speed = 4
    assert_equal 1, UI.timers.length
    assert_in_delta 0.05, UI.delays.last
    UI.drain
    assert_equal [0, 1, 2], @calls
  end

  def test_invalid_settings_rejected_before_any_write
    [0, -1, 5, Float::INFINITY, Float::NAN, 'bad'].each do |value|
      assert_raises(ArgumentError) { runner.speed = value }
    end
    assert_raises(ArgumentError) { runner.mode = :video }
    assert_raises(ArgumentError) { runner(mode: :unknown) }
    assert_empty @model.events
  end

  def test_empty_steps_rejected
    assert_raises(ArgumentError) { runner(0) }
  end

  def test_duplicate_step_id_rejected
    steps = 2.times.map { {id: 'same', label: 'a', action: ->(*) {}} }
    assert_raises(ArgumentError) { Runner.new(model: @model, steps: steps, plan_id: 'p') }
  end

  def test_invalid_steps_and_interval_rejected
    [{label: '', action: ->(*) {}}, {label: 'x', action: 'code'}, 'bad'].each do |step|
      assert_raises(ArgumentError) { Runner.new(model: @model, steps: [step], plan_id: 'p') }
    end
    assert_raises(ArgumentError) { runner(interval: 0) }
    assert_raises(ArgumentError) { runner(interval: Float::INFINITY) }
  end

  def test_duplicate_plan_after_completion_rejected
    job = runner.start
    UI.drain
    job.root.name = 'User renamed this group'
    assert_raises(Studio::DuplicatePlanError) { runner.start }
  end

  def test_duplicate_plan_after_cancellation_rejected
    job = runner.start
    UI.run_one
    job.cancel
    assert_raises(Studio::DuplicatePlanError) { runner.start }
  end

  def test_new_plan_creates_variant_without_deleting_prior_content
    prior = @model.entities.add_group
    prior.name = 'User furniture'
    runner.start
    UI.drain
    assert prior.valid?
    assert_equal 'User furniture', @model.entities.groups.first.name
    assert_equal 2, @model.entities.length
  end

  def test_first_step_failure_rolls_back_new_root
    job = runner { |entities, _data| entities.add_group; raise 'bad face' }.start
    UI.drain
    assert_equal :failed, job.state
    assert_equal 0, job.snapshot[:completed]
    assert_equal 0, @model.entities.length
    assert_nil job.root
    assert_equal 's0', job.snapshot[:error][:step_id]
    assert_includes job.snapshot[:error][:message], 'bad face'
    refute @model.open_operation
  end

  def test_late_failure_rolls_back_only_current_step
    count = 0
    job = runner do |entities, _data|
      count += 1
      entities.add_group
      raise 'second fails' if count == 2
    end.start
    UI.drain
    assert_equal :failed, job.state
    assert_equal 1, job.root.entities.length
    assert_equal 1, job.snapshot[:completed]
    assert_equal 1, job.root.get_attribute(Studio::DICTIONARY, 'completed_steps')
    assert_equal [:start, :commit, :start, :abort], @model.events.map(&:first)
  end

  def test_failure_before_first_step_allows_clean_resubmit
    runner { |*, **| raise 'fails' }.start
    UI.drain
    assert_equal 0, @model.entities.length
    assert_equal :running, runner.start.state
  end

  def test_start_operation_false_does_not_write
    @model.fail_start = true
    job = runner.start
    UI.drain
    assert_equal :failed, job.state
    assert_empty @calls
    assert_equal 0, @model.entities.length
  end

  def test_commit_false_is_not_reported_completed
    @model.fail_commit = true
    job = runner.start
    UI.drain
    assert_equal :failed, job.state
    assert_equal 0, job.snapshot[:completed]
    assert_equal 0, @model.entities.length
    refute @model.open_operation
  end

  def test_abort_error_is_explicit_warning
    @model.fail_abort = true
    job = runner { |*, **| raise 'step failed' }.start
    capture_io { UI.drain }
    assert_equal :failed, job.state
    assert job.snapshot[:warnings].any? { |w| w.include?('回滚失败') }
  end

  def test_model_switch_stops_without_writing_to_either_model
    job = runner.start
    Sketchup.active_model = FakeModel.new
    UI.drain
    assert_equal :failed, job.state
    assert_equal 0, @model.entities.length
    assert_equal 0, Sketchup.active_model.entities.length
  end

  def test_closed_model_rejected
    @model.is_valid = false
    assert_raises(Studio::ContextError) { runner.start }
  end

  def test_edit_context_rejected_before_start
    @model.active_path = [Object.new]
    assert_raises(Studio::ContextError) { runner.start }
    assert_empty @model.events
  end

  def test_nondefault_active_tag_rejected_without_changing_it
    @model.active_layer = @model.layers[1]
    assert_raises(Studio::ContextError) { runner.start }
    assert_equal @model.layers[1], @model.active_layer
  end

  def test_active_tag_change_during_build_stops
    job = runner.start
    UI.run_one
    @model.active_layer = @model.layers[1]
    UI.drain
    assert_equal :failed, job.state
    assert_equal [0], @calls
  end

  def test_removed_root_stops_build
    job = runner.start
    UI.run_one
    job.root.is_valid = false
    UI.drain
    assert_equal :failed, job.state
    assert_equal [0], @calls
  end

  def test_locked_root_stops_build
    job = runner.start
    UI.run_one
    job.root.is_locked = true
    UI.drain
    assert_equal :failed, job.state
  end

  def test_hidden_root_stops_build
    job = runner.start
    UI.run_one
    job.root.is_hidden = true
    UI.drain
    assert_equal :failed, job.state
  end

  def test_external_transaction_is_detected_before_next_step
    job = runner.start
    UI.run_one
    @model.start_operation('user edit', true)
    @model.entities.add_group
    @model.commit_operation
    assert job.snapshot[:context_invalidated]
    UI.drain
    assert_equal :failed, job.state
    assert_equal [0], @calls
  end

  def test_own_deferred_transaction_notifications_not_misclassified
    job = runner.start
    UI.drain
    assert_equal :completed, job.state
    refute job.snapshot[:context_invalidated]
  end

  def test_undo_while_paused_blocks_resume
    job = runner.start
    UI.run_one
    job.pause
    @model.notify(:onTransactionUndo)
    refute job.resume
    assert_equal :failed, job.state
  end

  def test_redo_and_edit_context_observers_only_flag
    job = runner.start
    @model.notify(:onTransactionRedo)
    assert_equal :running, job.state
    assert_empty @model.events
    UI.drain
    assert_equal :failed, job.state
  end

  def test_timer_start_failure_releases_busy_lock
    UI.fail_timer = true
    job = runner.start
    assert_equal :failed, job.state
    assert_nil Studio.current_runner
    assert_empty @model.observers
  end

  def test_fast_mode_processes_bounded_batch_and_same_step_order
    job = runner(70, mode: :fast).start
    UI.run_one
    assert_operator @calls.length, :<=, Runner::FAST_BATCH_LIMIT
    assert_operator @calls.length, :>, 0
    assert_equal :running, job.state
    UI.drain
    assert_equal (0...70).to_a, @calls
    assert_equal :completed, job.state
  end

  def test_switching_to_fast_does_not_duplicate_actions
    job = runner(50).start
    UI.run_one
    job.mode = :fast
    assert_equal 1, UI.timers.length
    UI.drain
    assert_equal (0...50).to_a, @calls
  end

  def test_slow_step_yields_and_warns
    job = runner(2, mode: :fast)
    time = -0.3
    job.define_singleton_method(:monotonic) { time += 0.3 }
    job.start
    capture_io { UI.run_one }
    assert_equal [0], @calls
    assert job.snapshot[:warnings].any? { |w| w.include?('200ms') }
  end

  def test_history_bounded_and_phase_progress_correct
    job = runner(70, mode: :fast).start
    UI.drain
    s = job.snapshot
    assert_equal 20, s[:recent_steps].length
    assert_equal 1, s[:phases][0][:completed]
    assert_equal 69, s[:phases][1][:completed]
  end

  def test_bad_listener_does_not_fail_geometry
    job = runner
    job.on_change { |_s| raise 'consumer error' }
    capture_io { job.start; UI.drain }
    assert_equal :completed, job.state
    assert job.snapshot[:warnings].any? { |w| w.include?('consumer error') }
  end

  def test_listener_cannot_mutate_other_snapshots
    job = runner
    job.on_change { |s| s[:title].replace('hacked'); s[:phases].clear }
    job.start
    assert_equal '建模生成', job.snapshot[:title]
    refute_empty job.snapshot[:phases]
  end

  def test_listener_can_pause_at_step_boundary
    job = runner
    job.on_change { |s| job.pause if s[:state] == 'running' && s[:completed] == 1 }
    job.start
    UI.drain
    assert_equal :paused, job.state
    assert_equal [0], @calls
  end

  def test_controls_cannot_reenter_open_transaction
    job = nil
    job = runner(1) do |*, **|
      refute job.pause
      refute job.cancel
      refute job.step_once
      assert_raises(Studio::BusyError) { job.speed = 2 }
      assert_raises(Studio::BusyError) { job.mode = :fast }
    end
    job.start
    UI.drain
    assert_equal :completed, job.state
  end

  def test_redraw_failure_does_not_claim_committed_geometry_failed
    @model.active_view.fail_redraw = true
    job = runner.start
    capture_io { UI.drain }
    assert_equal :completed, job.state
    assert_equal 3, job.snapshot[:completed]
    assert job.snapshot[:warnings].any? { |w| w.include?('视口刷新失败') }
  end

  def test_report_json_exclusive_write
    job = runner.start
    UI.drain
    Dir.mktmpdir do |directory|
      path = File.join(directory, '任务.json')
      assert_equal path, job.write_report(path)
      data = JSON.parse(File.read(path))
      assert_equal 'completed', data['state']
      assert_raises(Errno::EEXIST) { job.write_report(path) }
    end
  end

  def test_background_thread_is_rejected
    job = runner
    error = Thread.new { begin; job.start; rescue StandardError => e; e; end }.value
    assert_instance_of ThreadError, error
    assert_empty @model.events
  end
end
