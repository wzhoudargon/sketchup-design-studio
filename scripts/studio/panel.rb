# frozen_string_literal: true
require 'json'

module SketchupDesignStudio
  class Panel
    attr_reader :runner

    def initialize(runner)
      @runner = runner
      @ready, @closed = false, false
      @dialog = UI::HtmlDialog.new(
        dialog_title: 'SketchUp 空间设计工作室 · 生成过程',
        preferences_key: 'sketchup_design_studio.animation.v1',
        scrollable: true, resizable: true, width: 460, height: 600,
        min_width: 370, min_height: 430, style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(File.join(__dir__, 'panel.html'))
      @dialog.add_action_callback('studio_ready') do |_context|
        @ready = true
        render(@runner.snapshot)
      end
      bind('studio_pause') { @runner.pause }
      bind('studio_resume') { @runner.resume }
      bind('studio_step') { @runner.step_once }
      bind('studio_cancel') { @runner.cancel }
      bind('studio_speed') { |value| @runner.speed = value }
      bind('studio_mode') { |value| @runner.mode = value }
      bind('studio_report') { export_report }
      @dialog.set_on_closed do
        @closed, @ready = true, false
        @runner.remove_listener(@listener)
        # Do not silently continue building after the user closes the controls.
        @runner.pause if @runner.state == :running
      end
      @listener = @runner.on_change { |status| render(status) }
    end

    def show
      raise '面板已关闭，请使用 SketchupDesignStudio.show_panel 重新打开' if @closed
      @dialog.show
      @dialog.bring_to_front
      self
    end

    def closed?
      @closed
    end

    def close
      @dialog.close unless @closed
    end

    private

    def bind(name, &action)
      @dialog.add_action_callback(name) do |_context, *arguments|
        begin
          action.call(*arguments)
        rescue StandardError => e
          show_message(e.message)
        ensure
          render(@runner.snapshot)
        end
      end
    end

    def render(status)
      return unless @ready && !@closed
      @dialog.execute_script("window.StudioPanel.render(#{serialize(status)});")
    end

    def show_message(message)
      return unless @ready && !@closed
      @dialog.execute_script("window.StudioPanel.message(#{serialize(message.to_s)});")
    end

    def serialize(value)
      JSON.generate(value).gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
    end

    def export_report
      # Pause before opening a modal file chooser; never use modal UI inside ticks.
      @runner.pause if @runner.state == :running
      path = UI.savepanel('导出任务记录（不保存模型）', nil, "生成记录_#{@runner.job_id[0, 8]}.json")
      return unless path
      @runner.write_report(path)
      show_message('记录已导出。模型没有自动保存；若任务暂停，可点击继续。')
    end
  end
end
