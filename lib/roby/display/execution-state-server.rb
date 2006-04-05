require 'Qt'

module Roby
    class ExecutionStateDisplayServer < Qt::Object
	BASE_DURATION = 10000
	BASE_LINES    = 10

	attr_reader :line_height, :resolution, :start_time, :margin
	attr_reader :canvas, :view
	def initialize
	    super

	    @start_time	    = nil # start time (time of the first event)
	    @resolution	    = BASE_DURATION / 640 # resolution for time axis in ms per pixel
	    @line_height    = 30  # height of a line in pixel
	    standalone_line = Struct.new(:index).new(0)
	    @lines = [standalone_line] # active tasks for each line, the first line is for events not related to a task
	    @tasks	    = Array.new # list of known task objects
	    @margin	    = 10
	    
	    @canvas = Qt::Canvas.new(640, line_height * BASE_LINES + margin * 2)
	    @view   = Qt::CanvasView.new(canvas)

	    @hidden = true

	    @updater = Qt::Timer.new(self, "timer")
	    @updater.connect(@updater, SIGNAL('timeout()'), self, SLOT('update()'))
	    @updater.start(0)
 	end

	def hide
	    @view.hide
	    @hidden = true
	end

	def show
	    @view.show
	    @hidden = false
	end

	class CanvasTask < Qt::CanvasRectangle
	    attr_reader :start
	    attr_accessor :stop
	    attr_reader :task, :index
	    def start=(x)
		@start = x
		@title.x = x
	    end

	    def initialize(display, task, index)
		@task, @index = task, index
		line_height = display.line_height
		y = index * line_height
		super(0, y, 0, line_height * 0.4, display.canvas)
		yield(self) if block_given?
		
		self.brush = Qt::Brush.new(Qt::Color.new('#61d2ff'))
		self.z = -1

		@title = Qt::CanvasText.new(task.model.name, canvas) do |t|
		    t.visible = true
		    t.y = y + line_height / 2
		end

		self
	    end
	end

	def display_task(task, index)
	    CanvasTask.new(self, task, index) { |r| r.visible = true }
	end

	def line_of(event)
	    if event.respond_to?(:task)
		task = event.task
		puts event.inspect
		puts task.inspect

		# Get the line index for the task
		idx = @lines.enum_for(:each_with_index).find { |r, idx| r.task == task if r.respond_to?(:task) } ||
		    @lines.enum_for(:each_with_index).find { |r, idx| !r } ||
		    [nil, @lines.size]
		idx = idx.last

		# Build the task representation if necessary
		line = (@lines[idx] ||= display_task(task, idx))
		line
	    else
		@lines[0]
	    end
	end
	def x_of(time)
	    @start_time = time if !start_time
	    x = (time - @start_time) * 1000 / resolution
	    # TODO make sure x is in the canvas
	end

	def new_event(time, generator)
	    x	    = x_of(time)
	    line    = line_of(generator)

	    if line.respond_to?(:task)
		if !line.start
		    line.start = x
		    line.x = x
		end
		line.stop = x
		line.setSize(line.stop - line.start, line.height)
		line.visible = true
		line.brush = Qt::Brush.new(Qt::Color.new('cyan'))
	    end
	    
	    y = line.index * line_height + line_height * 0.2
	    shape = yield(x, y)

	    shape.move(x, y)
	    shape.visible = true
	end

	def pending_event(time, event_generator)
	    new_event(time, event_generator) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, canvas) do |e|
		    e.brush = Qt::Brush.new(Qt::Color.new('lightgrey'))
		end
	    end
	    nil
	end

	def fired_event(time, event_generator, event)
	    new_event(time, event_generator) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, canvas) do |e|
		    e.brush = Qt::Brush.new(Qt::Color.new('black'))
		end
	    end
	    nil
	end

	def update()
	    Thread.pass
	    if !@hidden
		canvas.update
		view.update
	    end
	end
	slots "update()"
    end
end


