require 'Qt'
require 'roby/display/style'

module Roby
    class PendingView < Qt::ListView
	attr_reader :pending

	class Task < Qt::ListViewItem
	    def initialize(view, task)
		super(view)
		set_text(0, task.model.name << " 0x" << task.source_address.to_s(16))
	    end
	end

	class Event < Qt::ListViewItem
	    def event_name(event, with_task = true)
		expr = ""

		if event.respond_to?(:task) && with_task
		    expr << event.task.source_class.to_s
		end

		if event.respond_to?(:symbol)
		    expr << "[" << event.symbol.to_s << "]"
		else
		    expr << event.model.name
		end

		expr.gsub!(/^Roby::(?:Genom::)?/, '') 
		expr << " 0x" << event.source_address.to_s(16)
	    end


	    def initialize(list, task, kind, time, obj, *args)
		super(list)
		set_text(0, "#{time.tv_sec}:#{"%03i" % (time.tv_usec / 1000)}")
		if task
		    set_text(1, task.model.name)
		else
		    set_text(1, "toplevel")
		end
		set_text(2, kind.to_s)

		expr = event_name(obj, false)

		if kind == :signal
		    dest = *args
		    expr << " -> " << event_name(dest)

		elsif kind == :postponed
		    wait_for, reason = *args
		    expr << " waiting for " << event_name(wait_for) << ": " << reason
		end
		set_text(3, expr)
	    end
	end

	def initialize(parent)
	    super(parent)
	    self.root_is_decorated = true
	    add_column "at"
	    add_column "in"
	    add_column "kind"
	    add_column "events"
	    @pending = Hash.new
	end

	def item_parent(generator)
	    if generator.respond_to?(:task)
		pending[generator.task] ||= Task.new(self, generator.task)
	    else
		self
	    end
	end

	def new_event(kind, time, generator, *args)
	    @reference ||= time
	    offset = time - @reference
	    time = Time.at(offset.to_i, (offset - offset.to_i) * 1000000)

	    task = generator.task if generator.respond_to?(:task)
	    Event.new(self, task, kind, time, generator, *args)
	end
	def pending_event(time, generator)
	    new_event(:pending, time, generator)
	end
	def fired_event(time, generator, event)
	    new_event(:fired, time, generator, event)
	end
	def signalling(time, from, to)
	    new_event(:signal, time, from, to)
	end
	def postponed(time, generator, wait_for, reason)
	    new_event(:postponed, time, generator, wait_for, reason)
	end
    end
    
    class ExecutionStateDisplayServer < Qt::Object
	BASE_DURATION = 3000
	BASE_LINES    = 10
	include Roby::DisplayStyle

	attr_reader :line_height, :resolution, :start_time, :margin, :event_radius
	attr_reader :canvas, :main_window
	attr_reader :event_display, :event_source
	def initialize
	    super

	    @resolution	    = BASE_DURATION / 640 # resolution for time axis in ms per pixel
	    @line_height    = 40  # height of a line in pixel
	    @event_radius   = 4
	    @margin	    = 10

	    @start_time	    = nil # start time (time of the first event)
	    @lines = [CanvasLine.new(0)] # active tasks for each line, the first line is for events not related to a task
	    # @tasks	    = Array.new # list of known task objects
	    
	    @canvas = Qt::Canvas.new(640, line_height * BASE_LINES + margin * 2)
	    
	    @main_window = Qt::Splitter.new(Qt::Vertical)
	    
	    @view   = Qt::CanvasView.new(@canvas, @main_window)
	    @pending = PendingView.new(@main_window)

	    @hidden = true
	    @event_display = Hash.new
	    @event_source = Hash.new
 	end

	def hidden?; @hidden end
	def hide
	    @main_window.hide
	    @hidden = true
	end
	def show
	    @main_window.show
	    @hidden = false
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
		self
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

		self
	    end
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

	def pending_event(time, event_generator)
	    changed!
	    circle = new_event(time, event_generator, true) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, canvas)
	    end
	    
	    if source = event_source.delete(event_generator)
		raise unless event_display.has_key?(source)
		source = event_display[source]
		DisplayStyle.arrow(source.x, source.y, circle.x, circle.y, self)

		Qt::CanvasLine.new(canvas) do |c|
		    c.set_points source.x, source.y, circle.x, circle.y
		    c.brush = Qt::Brush.new(Qt::Color.new(DisplayStyle::SIGNAL_COLOR))
		    c.pen = Qt::Pen.new(Qt::Color.new(DisplayStyle::SIGNAL_COLOR))
		    c.visible = true
		end
	    end

	    @pending.pending_event(time, event_generator)

	    nil
	end

	def fired_event(time, event_generator, event)
	    changed!
	    circle = new_event(time, event_generator, false) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, canvas)
	    end

	    @pending.fired_event(time, event_generator, event)
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
		    

	    nil
	end

	def signalling(time, from, to)
	    changed!
	    event_source[to] = from
	    @pending.signalling(time, from, to)
	end

	def postponed(time, generator, wait_for, reason)
	    @pending.postponed(time, generator, wait_for, reason)
	end
    end
end


