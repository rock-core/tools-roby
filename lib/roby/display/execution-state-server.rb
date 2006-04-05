require 'Qt'

module Roby
    class ExecutionStateDisplayServer < Qt::Object
	BASE_DURATION = 10000
	BASE_LINES    = 10

	attr_reader :line_height, :resolution, :start_time, :margin
	attr_reader :canvas, :view
	attr_reader :event_display, :event_source
	def initialize
	    super

	    @start_time	    = nil # start time (time of the first event)
	    @resolution	    = BASE_DURATION / 640 # resolution for time axis in ms per pixel
	    @line_height    = 30  # height of a line in pixel
	    @lines = [CanvasLine.new(0)] # active tasks for each line, the first line is for events not related to a task
	    @tasks	    = Array.new # list of known task objects
	    @margin	    = 10
	    
	    @canvas = Qt::Canvas.new(640, line_height * BASE_LINES + margin * 2)
	    @view   = Qt::CanvasView.new(canvas)

	    @hidden = true
	    @event_display = Hash.new
	    @event_source = Hash.new

	    @updater = Qt::Timer.new(self, "timer")
	    @updater.connect(@updater, SIGNAL('timeout()'), self, SLOT('update()'))
	    @updater.start(0)
 	end

	def hidden?; @hidden end
	def hide
	    @view.hide
	    @hidden = true
	end
	def show
	    @view.show
	    @hidden = false
	end

	# [ light, dark ] array of colors for events
	TASK_COLOR = '#B0FFA6'
	SIGNAL_COLOR = 'black'
	EVENT_COLORS = [
	    [ 'lightgrey', 'black' ],
	    [ '#AFF6FF', '#4DD0FF' ]
	]

	class CanvasLine
	    attr_reader :index
	    attr_reader :colors
	    def next_color
		@color_index = (@color_index + 1) % EVENT_COLORS.size
		EVENT_COLORS[@color_index]
	    end

	    def initialize(index)
		@index = index
		@colors = Hash.new
		@color_index = -1
		self
	    end
	end

	class CanvasTask < CanvasLine
	    attr_reader :start, :stop
	    attr_reader :task
	    def start=(x)
		@start = x
		@rectangle.x = x
		@title.x = x
	    end

	    def stop=(x)
		@stop = x
		@rectangle.set_size(stop - start, @rectangle.height)
	    end

	    def initialize(display, task, index)
		super(index)

		@task = task
		line_height = display.line_height
		y = index * line_height

		@rectangle = Qt::CanvasRectangle.new(0, y, 0, line_height * 0.4, display.canvas) do |r|
		    r.brush = Qt::Brush.new(Qt::Color.new(TASK_COLOR))
		    r.pen = Qt::Pen.new(Qt::Color.new(TASK_COLOR))
		    r.visible = true
		    r.z = -1
		end

		@title = Qt::CanvasText.new(task.model.name, display.canvas) do |t|
		    t.visible = true
		    t.y = y + line_height * 0.4
		    font = t.font
		    font.pixel_size = line_height / 2
		    t.font = font
		    t.text_flags = Qt::AlignTop
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

	def new_event(time, generator, light_color)
	    x	    = x_of(time)
	    line    = line_of(generator)

	    if line.respond_to?(:task)
		line.start = x if !line.start
		line.stop = x
	    end
	    
	    y = line.index * line_height + line_height * 0.2
	    shape = yield(x, y)

	    shape.move(x, y)
	    shape.visible = true

	    # TODO: manage the case where we have pending more than one command
	    # TODO: from the same generator

	    unless colors = line.colors.delete(generator)
		colors = line.next_color
		line.colors[generator] = colors
	    end
	    shape.brush = Qt::Brush.new(Qt::Color.new(light_color ? colors[0] : colors[1]))
	    shape
	end

	def pending_event(time, event_generator)
	    changed!
	    circle = new_event(time, event_generator, true) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, canvas)
	    end
	    
	    if source = event_source.delete(event_generator)
		source = event_display[source]
		Qt::CanvasLine.new(canvas) do |c|
		    c.set_points source.x, source.y, circle.x, circle.y
		    c.brush = Qt::Brush.new(Qt::Color.new(SIGNAL_COLOR))
		    c.pen = Qt::Pen.new(Qt::Color.new(SIGNAL_COLOR))
		    c.visible = true
		end
	    end

	    nil
	end

	def fired_event(time, event_generator, event)
	    changed!
	    circle = new_event(time, event_generator, false) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, canvas)
	    end
	    
	    event_display[event] = circle

	    nil
	end

	def signalling(time, from, to)
	    event_source[to] = from
	end

	def update()
	    Thread.pass
	    if !hidden? && changed?
		canvas.update
		@changed = false
	    end
	end
	slots "update()"

	def changed?; @changed end
	def changed!; @changed = true end
    end
end


