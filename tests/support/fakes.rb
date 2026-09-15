# frozen_string_literal: true
# Simulated API contracts, not the SketchUp geometry kernel or UI event loop.
$LOAD_PATH.unshift(__dir__)
module UI
  class << self
    attr_accessor :fail_timer, :fail_stop, :save_path
    attr_reader :timers, :callbacks, :delays
    def reset
      @timers, @callbacks, @delays, @sequence = {}, [], [], 0
      @fail_timer = @fail_stop = false
      @save_path = nil
      HtmlDialog.instances.clear
    end
    def start_timer(delay, repeat, &block)
      raise 'timer unavailable' if @fail_timer
      raise 'Only one-shot timers expected' if repeat
      @sequence += 1
      @timers[@sequence] = block
      @callbacks << block
      @delays << delay
      @sequence
    end
    def stop_timer(id)
      raise 'stop unavailable' if @fail_stop
      @timers.delete(id)
    end
    def run_one
      id = @timers.keys.first
      @timers[id].call if id
    end
    def drain(limit = 1000)
      limit.times do
        return if @timers.empty?
        run_one
      end
      raise 'Timer drain exhausted'
    end
    def savepanel(*_args)
      @save_path
    end
  end
  class HtmlDialog
    STYLE_DIALOG = 0
    class << self
      def instances
        @instances ||= []
      end
    end
    attr_accessor :fail_script
    attr_reader :scripts, :callbacks, :path, :properties, :shown
    def initialize(properties)
      @properties, @scripts, @callbacks = properties, [], {}
      self.class.instances << self
    end
    def set_file(path)
      raise 'Missing HTML' unless File.file?(path)
      @path = path
    end
    def add_action_callback(name, &block)
      @callbacks[name] = block
      true
    end
    def set_on_closed(&block)
      @on_closed = block
    end
    def execute_script(script)
      raise 'dialog gone' if @fail_script
      @scripts << script
    end
    def show
      @shown = true
    end
    def bring_to_front; end
    def close
      @shown = false
      @on_closed.call if @on_closed
      @callbacks.clear
    end
    def trigger(name, *args)
      @callbacks.fetch(name).call(nil, *args)
    end
  end
end

module Sketchup
  class ModelObserver; end
  class Face; end
  Color = Struct.new(:red, :green, :blue)
  class << self
    attr_accessor :active_model
    def version
      '22.0.0'
    end
  end
end

class FakeEntities
  include Enumerable
  attr_reader :groups, :model
  def initialize(model)
    @groups, @model = [], model
  end
  def each(&block)
    @groups.each(&block)
  end
  def add_group
    group = FakeGroup.new(@model)
    @groups << group
    group
  end
  def length
    @groups.length
  end
  def checkpoint
    @groups.map { |g| [g, Marshal.load(Marshal.dump(g.attributes)), g.entities.checkpoint, g.name, g.layer] }
  end
  def restore(checkpoint)
    preserved = checkpoint.map(&:first)
    (@groups - preserved).each { |g| g.is_valid = false }
    @groups = preserved
    checkpoint.each do |g, attributes, children, name, layer|
      g.attributes = attributes
      g.entities.restore(children)
      g.name, g.layer = name, layer
    end
  end
end

class FakeGroup
  attr_accessor :name, :layer, :is_valid, :is_locked, :is_hidden, :attributes
  attr_reader :entities
  def initialize(model)
    @entities, @attributes = FakeEntities.new(model), {}
    @is_valid, @is_locked, @is_hidden = true, false, false
  end
  def valid?; @is_valid; end
  def locked?; @is_locked; end
  def hidden?; @is_hidden; end
  def set_attribute(dictionary, key, value)
    @attributes[[dictionary, key]] = value
  end
  def get_attribute(dictionary, key, default = nil)
    @attributes.fetch([dictionary, key], default)
  end
end

class FakeView
  attr_accessor :fail_redraw
  attr_reader :redraws
  def initialize
    @redraws = 0
  end
  def invalidate
    raise 'redraw unavailable' if @fail_redraw
    @redraws += 1
  end
end

class FakeMaterials
  Material = Struct.new(:name, :color)
  attr_reader :items
  def initialize
    @items = []
  end
  def add(name)
    item = Material.new(name, nil)
    @items << item
    item
  end
end

class FakeModel
  attr_accessor :active_path, :active_layer, :is_valid, :fail_start, :fail_commit, :fail_abort
  attr_reader :entities, :active_view, :events, :layers, :open_operation, :observers, :materials
  def initialize
    @entities, @active_view, @events = FakeEntities.new(self), FakeView.new, []
    @layers, @observers = [Object.new, Object.new], []
    @active_layer, @active_path, @is_valid, @open_operation = @layers[0], nil, true, false
    @materials = FakeMaterials.new
  end
  def valid?; @is_valid; end
  def add_observer(observer)
    @observers << observer
    true
  end
  def remove_observer(observer)
    @observers.delete(observer)
    true
  end
  def notify(event)
    @observers.dup.each { |o| o.public_send(event, self) if o.respond_to?(event) }
  end
  def start_operation(name, disable_ui)
    return false if @fail_start
    raise 'Nested operation' if @open_operation
    raise 'disable_ui must be true' unless disable_ui
    @baseline = @entities.checkpoint
    @open_operation = true
    @events << [:start, name]
    true
  end
  def commit_operation
    raise 'No operation' unless @open_operation
    return false if @fail_commit
    @events << [:commit]
    # Real SketchUp can defer both these notifications until commit.
    notify(:onTransactionStart)
    notify(:onTransactionCommit)
    @open_operation = false
    true
  end
  def abort_operation
    raise 'abort unavailable' if @fail_abort
    raise 'No operation' unless @open_operation
    @entities.restore(@baseline)
    @open_operation = false
    @events << [:abort]
    notify(:onTransactionAbort)
    true
  end
end
