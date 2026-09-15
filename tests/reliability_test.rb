# frozen_string_literal: true
require 'minitest/autorun'
require_relative 'support/fakes'
require_relative '../scripts/sketchup_studio'

class ReliabilityTest < Minitest::Test
  Studio = SketchupDesignStudio
  D = Studio::DICTIONARY

  def setup
    old = Studio.instance_variable_get(:@panel)
    old.close if old && !old.closed?
    UI.reset
    @model = Sketchup.active_model = FakeModel.new
    Studio.current_runner = nil
    Studio.instance_variable_set(:@jobs, {})
    Studio.instance_variable_set(:@last_job_id, nil)
    Studio.instance_variable_set(:@panel, nil)
  end

  def submit(plan_id: 'regression', panel: false, count: 2)
    Studio.submit(plan_id: plan_id, panel: panel, steps: count.times.map { |i|
      {id: "part_#{i}", label: "构件 #{i}", phase: '建模',
       action: ->(entities, _data) { entities.add_group }}
    })
  end

  def completed(**options)
    job = submit(**options)
    UI.drain
    job
  end

  def test_checkpoint_rollback_without_observer_event
    job = submit
    UI.run_one
    previous = @model.entities.checkpoint
    UI.drain
    @model.entities.restore(previous)
    assert_equal :completed, job.state
    refute job.snapshot[:completion_valid]
    refute job.snapshot[:geometry_completed]
    error = assert_raises(Studio::ContextError) { Studio.assert_completed!(job.job_id) }
    assert_match(/completed_steps/, error.message)
  end

  def test_undo_and_redo_never_silently_restore_certification
    job = submit
    UI.run_one
    previous = @model.entities.checkpoint
    UI.drain
    final = @model.entities.checkpoint
    @model.entities.restore(previous)
    @model.notify(:onTransactionUndo)
    assert_raises(Studio::ContextError) { job.assert_completed! }
    @model.entities.restore(final)
    @model.notify(:onTransactionRedo)
    assert_equal 2, job.root.get_attribute(D, 'completed_steps')
    assert_raises(Studio::ContextError) { job.assert_completed! }
    assert_match(/撤销/, job.brief_snapshot[:completion_reason])
  end

  def test_six_checkpoint_fields_are_verified_without_writing
    job = completed
    baseline = Marshal.load(Marshal.dump(job.root.attributes))
    ['job_id', 'plan_id', 'runtime_version', 'completed_steps', 'total_steps', 'last_step_id'].each do |key|
      job.root.attributes = Marshal.load(Marshal.dump(baseline))
      job.root.set_attribute(D, key, 'corrupt')
      events = @model.events.length
      assert_raises(Studio::ContextError, key) { job.assert_completed! }
      assert_equal events, @model.events.length
      assert_match(/#{key}/, job.brief_snapshot[:completion_reason])
    end
    job.root.attributes = baseline
    assert_equal @model, job.assert_completed!
  end

  def test_foreign_commit_invalidates_without_editing_geometry
    job = completed
    assert_equal 1, @model.observers.length
    @model.start_operation('manual edit', true)
    @model.entities.add_group
    @model.commit_operation
    events, groups = @model.events.dup, @model.entities.length
    assert_raises(Studio::ContextError) { job.assert_completed! }
    assert_equal events, @model.events
    assert_equal groups, @model.entities.length
    assert job.snapshot[:context_invalidated]
  end

  def test_observer_defers_panel_notification
    job = completed(panel: true)
    dialog = UI::HtmlDialog.instances.last
    dialog.trigger('studio_ready')
    before = dialog.scripts.length
    @model.notify(:onTransactionUndo)
    assert_equal before, dialog.scripts.length
    UI.drain
    assert_equal before + 1, dialog.scripts.length
    assert_includes dialog.scripts.last, '"completion_valid":false'
    assert_equal :completed, job.state
  end

  def test_repeated_invalidations_coalesce
    job = completed(panel: true)
    @model.notify(:onTransactionUndo)
    revision = job.brief_snapshot[:revision]
    @model.notify(:onTransactionRedo)
    assert_equal revision, job.brief_snapshot[:revision]
    assert_equal 1, UI.timers.length
    UI.drain
  end

  def test_camera_redraw_does_not_invalidate
    job = completed
    @model.active_view.invalidate
    assert job.brief_snapshot[:completion_valid]
    assert_equal @model, job.assert_completed!
  end

  def test_enter_exit_edit_path_without_editing
    job = completed
    @model.active_path = [job.root]
    @model.notify(:onActivePathChanged)
    assert_raises(Studio::ContextError) { job.assert_completed! }
    @model.active_path = nil
    @model.notify(:onActivePathChanged)
    assert_equal @model, job.assert_completed!
  end

  def test_locked_hidden_invalid_group_or_closed_model
    job = completed
    job.root.is_locked = true
    assert_raises(Studio::ContextError) { job.assert_completed! }
    job.root.is_locked = false
    job.root.is_hidden = true
    assert_raises(Studio::ContextError) { job.assert_completed! }
    job.root.is_hidden = false
    @model.is_valid = false
    refute job.brief_snapshot[:completion_valid]
    @model.is_valid = true
    job.root.is_valid = false
    assert_raises(Studio::ContextError) { job.assert_completed! }
  end

  def test_model_delete_event
    job = completed
    @model.notify(:onDeleteModel)
    assert_raises(Studio::ContextError) { job.assert_completed! }
  end

  def test_dispose_releases_monitor_and_revokes_proof
    job = completed
    job.dispose!
    assert_empty @model.observers
    assert_raises(Studio::ContextError) { job.assert_completed! }
    job.dispose!
    assert_empty @model.observers
  end

  def test_dispose_only_terminal_jobs
    job = submit
    assert_raises(Studio::BusyError) { job.dispose! }
    job.pause
    assert_raises(Studio::BusyError) { job.dispose! }
    job.cancel
    job.dispose!
    assert_empty @model.observers
  end

  def test_registry_eviction_bounds_monitors
    first = nil
    17.times do |i|
      job = completed(plan_id: "registry.#{i}", count: 1)
      first ||= job
    end
    assert_equal 16, @model.observers.length
    assert_raises(ArgumentError) { Studio.job(first.job_id) }
    assert_raises(Studio::ContextError) { first.assert_completed! }
    assert Studio.job.brief_snapshot[:completion_valid]
  end

  def test_full_compatibility_and_brief_schema
    job = completed(count: 70)
    full, brief = Studio.status(job.job_id), Studio.status_brief(job.job_id)
    [:phases, :recent_steps, :warnings, :title, :started_at].each do |key|
      assert full.key?(key)
      refute brief.key?(key)
    end
    [:state, :job_id, :completed, :total, :completion_valid, :revision].each do |key|
      assert_equal full[key], brief[key]
    end
    assert_operator JSON.generate(brief).bytesize, :<, JSON.generate(full).bytesize
    assert_equal JSON.parse(Studio.status_brief_json(job.job_id)), JSON.parse(Studio.status_json(job.job_id, detail: :brief))
  end

  def test_brief_results_do_not_expose_mutable_internal_strings
    job = completed
    brief = job.brief_snapshot
    brief[:job_id].replace('bad')
    assert_equal job.job_id, job.brief_snapshot[:job_id]
  end

  def test_invalid_detail_does_not_execute_control
    job = submit
    assert_raises(ArgumentError) { Studio.control(job.job_id, 'cancel', detail: :unknown) }
    assert_equal :running, job.state
    assert_raises(ArgumentError) { Studio.status(job.job_id, detail: :unknown) }
    assert_equal 'paused', Studio.control(job.job_id, 'pause', detail: :brief)[:state]
  end

  def test_error_excerpt_keeps_full_diagnostics
    job = Studio.submit(plan_id: 'error', panel: false, steps: [
      {id: 'broken', label: '异常', action: ->(_e, _d) { raise 'x' * 1000 }}
    ])
    UI.drain
    assert_equal 'failed', job.brief_snapshot[:state]
    assert_equal 320, job.brief_snapshot[:error][:message].length
    assert_equal 1000, job.snapshot[:error][:message].length
    assert_empty @model.observers
  end

  def test_gate_is_main_thread_only
    job = completed
    result = Thread.new do
      begin
        job.assert_completed!
      rescue StandardError => error
        error
      end
    end.value
    assert_instance_of ThreadError, result
  end
  def test_dispose_still_revokes_proof_when_timer_stop_fails
    job = completed(panel: true)
    @model.notify(:onTransactionUndo)
    callback = UI.callbacks.last
    UI.fail_stop = true
    _out, err = capture_io { job.dispose! }
    assert_match(/计时器失败/, err)
    assert_empty @model.observers
    assert_raises(Studio::ContextError) { job.assert_completed! }
    UI.fail_stop = false
    callback.call
    assert_empty job.instance_variable_get(:@listeners)
  end

end
