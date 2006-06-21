module Roby
    class ExecutionStateCanvas < Qt::Canvas
	include Roby::DisplayStyle

	BASE_DURATION = 6000
	BASE_LINES    = 10

	def canvas; self end

	attr_reader :line_height, :resolution, :start_time, :margin, :event_radius
	attr_reader :event_display, :event_source
	def initialize
	    @resolution	    = BASE_DURATION / 640 # resolution for time axis in ms per pixel
	    @line_height    = 40  # height of a line in pixel
	    @event_radius   = 4
	    @margin	    = 10
	    @event_display = Hash.new
	    @event_source  = Hash.new

	    @start_time	    = nil # start time (time of the first event)
	    super(640, line_height * BASE_LINES + margin * 2)

	    @lines = [CanvasLine.new(0)] # active tasks for each line, the first line is for events not related to a task
	end

	def allocate_task(task_object, x)
	    # Get the line index for the task
	    idx = @lines.enum_for(:each_with_index).find do |r, _| 
		if !r
		    true
		else
		    r.task.finished? && (r.start + r.width) < x if r.respond_to?(:task)
		end
	    end

	    idx = if idx
		      idx.last
		  else
		      @lines.size
		  end

	    @lines[idx] = CanvasTask.new(self, task_object, idx) { |r| r.visible = true }
	    [@lines[idx], idx]
	end

	# Returns [task, line_index] if event.task is already displayed
	def task_of(event)
	    @lines.enum_for(:each_with_index).find { |r, _| r.task == event.task if r.respond_to?(:task) }
	end

	def line_of(event, x)
	    if event.respond_to?(:task)
		(task_of(event) || allocate_task(event.task, x)).first
	    else
		@lines[0]
	    end
	end
	def x_of(time)
	    @start_time = time if !start_time
	    x = (time - @start_time) * 1000 / resolution
	    # TODO make sure x is in the canvas
	end

	def new_event(time, generator, pending)
	    x	    = x_of(time)
	    line    = line_of(generator, x)

	    if line.respond_to?(:task)
		line.start = x if !line.start
		line.stop = x
	    end
	    
	    y = (line.index + 0.2) * line_height
	    shape = DisplayStyle.event(generator, self, pending)
	    shape.move(x, y)

	    new_width	= self.width * 2 if x > self.width
	    new_height	= self.height * 2 if y + line_height > self.height
	    if new_width || new_height
		resize(new_width || self.width, new_height || self.height)
	    end

	    # TODO: manage the case where we have pending more than one command
	    # TODO: from the same generator

	    unless colors = line.colors.delete(generator)
		colors = line.next_color
		line.colors[generator] = colors
	    end
	    shape.brush = Qt::Brush.new(Qt::Color.new(pending ? colors[0] : colors[1]))
	    shape.z -= 1 if pending
	    shape
	end


	class CanvasLine
	    attr_reader :index
	    attr_reader :colors
	    def next_color
		@color_index = (@color_index + 1) % DisplayStyle::EVENT_COLORS.size
		DisplayStyle::EVENT_COLORS[@color_index]
	    end

	    def initialize(index)
		@index = index
		@colors = Hash.new
		@color_index = -1
	    end
	end

	class CanvasTask < CanvasLine
	    attr_reader :start, :stop
	    attr_reader :task, :display
	    def start=(x)
		@start = x
		@display.move(x, @display.y)
	    end

	    def stop=(x)
		@stop = x
		r = @display.rectangle
		r.set_size(stop - start, r.height)
	    end

	    def width
		[@stop - @start, @display.title.bounding_rect.width].max
	    end

	    def initialize(display, task, index)
		super(index)

		@task = task
		line_height = display.line_height
		y = index * line_height

		@display = DisplayStyle.task(task, display)
		@display.show
		@display.move(0, y)
	    end
	end


	def pending_event(time, event_generator)
	    circle = new_event(time, event_generator, true) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, self)
	    end
	    
	    if source = event_source.delete(event_generator)
		raise unless event_display.has_key?(source)
		source = event_display[source]
		DisplayStyle.arrow(source.x, source.y, circle.x, circle.y, self)

		Qt::CanvasLine.new(self) do |c|
		    c.set_points source.x, source.y, circle.x, circle.y
		    c.brush = Qt::Brush.new(Qt::Color.new(DisplayStyle::SIGNAL_COLOR))
		    c.pen = Qt::Pen.new(Qt::Color.new(DisplayStyle::SIGNAL_COLOR))
		    c.visible = true
		end
	    end
	end

	def fired_event(time, event_generator, event)
	    circle = new_event(time, event_generator, false) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, self)
	    end

	    event_display[event] = circle

	    if event_generator.respond_to?(:task)
		task = task_of(event_generator).first
		case event_generator.symbol
		when :start
		    task.display.color = TASK_COLORS[:running]
		when :failed
		    task.display.color = TASK_COLORS[:failed]
		when :success
		    task.display.color = TASK_COLORS[:success]
		end
	    end
	end

	def signalling(time, from, to)
	    event_source[to] = from
	end
    end
end


