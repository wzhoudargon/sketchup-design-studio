# frozen_string_literal: true
require 'minitest/autorun'
require_relative 'support/fakes'
require_relative '../scripts/sketchup_studio'
require_relative '../examples/animated_pavilion'
require_relative '../examples/task_template'

class IntegrationTest < Minitest::Test
  Studio = SketchupDesignStudio
  def setup
    # Close an old panel first so its on_closed callback cannot alter the next job.
    old = Studio.instance_variable_get(:@panel)
    old.close if old && !old.closed?
    UI.reset
    Sketchup.active_model = FakeModel.new
    Studio.current_runner = nil
    Studio.instance_variable_set(:@jobs, {})
    Studio.instance_variable_set(:@last_job_id, nil)
    Studio.instance_variable_set(:@panel, nil)
  end

  def submit(panel: true, title: '集成测试')
    Studio.submit(plan_id: 'integration.v1', title: title, panel: panel, steps: [
      {label: '地台', action: ->(entities, _data) { entities.add_group }},
      {label: '屋面', action: ->(entities, _data) { entities.add_group }}
    ])
  end

  def test_bootstrap_load_is_non_destructive_and_idempotent
    load File.expand_path('../scripts/sketchup_studio.rb', __dir__)
    assert_equal 0, Sketchup.active_model.entities.length
    assert_empty UI.timers
    assert_empty UI::HtmlDialog.instances
  end

  def test_submit_returns_queryable_job_before_completion
    job = submit(panel: false)
    status = JSON.parse(Studio.status_json(job.job_id))
    assert_equal 'running', status['state']
    assert_equal 0, status['completed']
    UI.drain
    assert_equal 'completed', Studio.status(job.job_id)[:state]
    refute Studio.status(job.job_id)[:file_saved_by_runner]
  end

  def test_delivery_gate_rejects_running_paused_and_cancelled
    job = submit(panel: false)
    assert_raises(Studio::ContextError) { Studio.assert_completed!(job.job_id) }
    job.pause
    assert_raises(Studio::ContextError) { Studio.assert_completed!(job.job_id) }
    job.cancel
    assert_raises(Studio::ContextError) { Studio.assert_completed!(job.job_id) }
  end

  def test_delivery_gate_returns_model_only_after_completion
    job = submit(panel: false)
    UI.drain
    assert_equal Sketchup.active_model, Studio.assert_completed!(job.job_id)
  end

  def test_delivery_gate_rejects_switched_model
    job = submit(panel: false)
    UI.drain
    Sketchup.active_model = FakeModel.new
    assert_raises(Studio::ContextError) { Studio.assert_completed!(job.job_id) }
  end

  def test_control_allowlist_and_state
    job = submit(panel: false)
    assert_equal 'paused', Studio.control(job.job_id, 'pause')[:state]
    assert_equal 1, Studio.control(job.job_id, 'step')[:completed]
    assert_raises(ArgumentError) { Studio.control(job.job_id, 'eval', 'bad code') }
    assert_equal 'cancelled', Studio.control(job.job_id, 'cancel')[:state]
  end

  def test_unknown_job_is_not_silently_replaced
    assert_raises(ArgumentError) { Studio.status('unknown') }
  end

  def test_panel_ready_handshake_sends_latest_status
    job = submit
    dialog = UI::HtmlDialog.instances.last
    assert_empty dialog.scripts
    UI.run_one
    dialog.trigger('studio_ready')
    assert_includes dialog.scripts.last, '"completed":1'
    assert_equal job, Studio.job
  end

  def test_panel_buttons_control_real_runner
    job = submit
    dialog = UI::HtmlDialog.instances.last
    dialog.trigger('studio_ready')
    dialog.trigger('studio_pause')
    assert_equal :paused, job.state
    dialog.trigger('studio_step')
    assert_equal 1, job.snapshot[:completed]
    dialog.trigger('studio_speed', 2)
    assert_equal 2, job.snapshot[:speed]
    dialog.trigger('studio_mode', 'fast')
    dialog.trigger('studio_resume')
    UI.drain
    assert_equal :completed, job.state
  end

  def test_closing_panel_pauses_and_reopen_preserves_job
    job = submit
    original = UI::HtmlDialog.instances.last
    original.close
    assert_equal :paused, job.state
    assert_empty UI.timers
    Studio.show_panel(job.job_id)
    reopened = UI::HtmlDialog.instances.last
    refute_equal original, reopened
    reopened.trigger('studio_ready')
    reopened.trigger('studio_resume')
    UI.drain
    assert_equal :completed, job.state
  end

  def test_show_existing_panel_does_not_duplicate
    job = submit
    Studio.show_panel(job.job_id)
    assert_equal 1, UI::HtmlDialog.instances.length
  end

  def test_closed_panel_unsubscribes_listener
    job = submit
    dialog = UI::HtmlDialog.instances.last
    dialog.trigger('studio_ready')
    dialog.close
    script_count = dialog.scripts.length
    job.resume
    UI.drain
    assert_equal script_count, dialog.scripts.length
  end

  def test_invalid_ui_payload_has_visible_error_and_no_crash
    job = submit
    dialog = UI::HtmlDialog.instances.last
    dialog.trigger('studio_ready')
    dialog.trigger('studio_speed', 'infinity')
    assert_equal :running, job.state
    assert dialog.scripts.any? { |script| script.include?('StudioPanel.message') }
  end

  def test_json_serialization_handles_quotes_unicode_and_line_separators
    title = "中\"文</script>\u2028\u2029"
    submit(title: title)
    dialog = UI::HtmlDialog.instances.last
    dialog.trigger('studio_ready')
    script = dialog.scripts.last
    assert_includes script, '\\u2028'
    refute_includes script, "\u2028"
    json = script.sub('window.StudioPanel.render(', '').sub(/\);\z/, '')
    assert_equal title, JSON.parse(json)['title']
  end

  def test_report_file_dialog_pauses_even_when_cancelled
    job = submit
    dialog = UI::HtmlDialog.instances.last
    dialog.trigger('studio_report')
    assert_equal :paused, job.state
    assert_empty UI.timers
  end

  def test_failed_preflight_does_not_open_extra_panel
    submit
    assert_raises(Studio::BusyError) { submit }
    assert_equal 1, UI::HtmlDialog.instances.length
  end

  def test_demo_has_70_unique_steps_without_running_on_load
    steps = Studio::Examples::Pavilion.steps
    assert_equal 70, steps.length
    assert_equal 70, steps.map { |s| s[:id] }.uniq.length
    assert_equal ['地台', '立柱', '梁架', '顶棚', '细节'], steps.map { |s| s[:phase] }.uniq
    assert_equal 0, Sketchup.active_model.entities.length
  end

  def test_demo_refuses_nonempty_model
    Sketchup.active_model.entities.add_group
    assert_raises(Studio::ContextError) { Studio.demo }
    assert_equal 1, Sketchup.active_model.entities.length
  end

  def test_demo_both_modes_produce_identical_dimension_plan_using_geometry_spy
    results = [:animated, :fast].map do |mode|
      Sketchup.active_model = FakeModel.new
      records = {}
      box_spy = lambda do |_entities, **options|
        raise 'duplicate logical id' if records.key?(options[:id])
        records[options[:id]] = {origin: options[:origin].dup, size: options[:size].dup, name: options[:name]}
      end
      growth_spy = lambda { |record, height| record[:size][2] = height }
      Studio::Geometry.stub(:box_mm, box_spy) do
        Studio::Geometry.stub(:grow_to_mm, growth_spy) do
          job = Studio.submit(plan_id: 'pavilion.compare', mode: mode, panel: false, steps: Studio::Examples::Pavilion.steps)
          UI.drain
          assert_equal :completed, job.state
        end
      end
      assert_equal 26, records.length
      4.times { |i| assert_equal 3000, records.fetch("column.#{i + 1}")[:size][2] }
      records
    end
    assert_equal results[0], results[1]
  end

  def test_template_is_submittable_in_animated_mode_using_geometry_spy
    box_spy = ->(_entities, **options) { {size: options[:size].dup} }
    grow_spy = ->(record, height) { record[:size][2] = height }
    Studio::Geometry.stub(:box_mm, box_spy) do
      Studio::Geometry.stub(:grow_to_mm, grow_spy) do
        job = StudioExampleTask.submit
        UI.drain
        assert_equal :completed, job.state
        assert_equal 13, job.snapshot[:completed]
      end
    end
  end

  def test_geometry_input_validation_before_mutation
    entities = Sketchup.active_model.entities
    [[], [1, 2], [0, 1, 2], [1, -2, 3], [Float::NAN, 1, 2]].each do |size|
      assert_raises(ArgumentError) { Studio::Geometry.box_mm(entities, id: 'box', name: 'box', origin: [0, 0, 0], size: size) }
    end
    assert_equal 0, entities.length
  end
end
