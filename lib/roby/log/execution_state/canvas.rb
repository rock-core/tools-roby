module Roby
    class Display::ExecutionStateCanvas < Qt::Canvas
	include Roby::Display::Style

	BASE_WINDOW_WIDTH = 640
	BASE_RESOLUTION = 50 # ms per pixel
	BASE_LINES    = 10

	def canvas; self end

	attr_reader :line_height, :resolution, :start_time, :margin
	attr_reader :event_radius, :event_display, :event_source
	
	attr_reader :view
	def view=(view)
	    @view = view
	    connect(view, SIGNAL('horizontalSliderPressed()'),
		    SLOT('disable_scrolling()'))
	    connect(view, SIGNAL('horizontalSliderReleased()'),
		    SLOT('scrolled_horizontal()'))
	end

	def initialize
	    @resolution	    = BASE_RESOLUTION # resolution for time axis in ms per pixel
	    @line_height    = 40  # height of a line in pixel
	    @event_radius   = 4
	    @margin	    = 10

	    super(BASE_WINDOW_WIDTH, line_height * BASE_LINES + margin * 2)

	    clear
	end

	def clear
	    all_items.each { |it| it.dispose }

	    @start_time	    = nil # start time (time of the first event)
	    @event_display = Hash.new
	    @event_source  = Hash.new
	    @lines = [CanvasLine.new(0)] # active tasks for each line, the first line is for events not related to a task
	end

	def allocate_task(task_object, x)
	    # Get an empty line for the task
	    idx = @lines.enum_for(:each_with_index).find do |r, _| 
		if !r then true
		else r.finished? && (r.start + r.width) < x if r.respond_to?(:task)
		end
	    end

	    idx = if idx then idx.last
		  else @lines.size
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
	    else @lines[0]
	    end
	end
	def x_of(time)
	    @start_time = time if !start_time
	    x = (time - @start_time) * 1000 / resolution
	end

	def scrolling?
	    @scrolling != false
	end
	def disable_scrolling; @scrolling = false end
	slots 'disable_scrolling()'
	def scrolled_horizontal
	    scrollbar = view.horizontal_scroll_bar
	    @scrolling = (scrollbar.value == scrollbar.max_value)
	end
	slots 'scrolled_horizontal()'

	def ping(time)
	    x	    = x_of(time)
	    @lines.each do |t|
		next unless t.respond_to?(:task)
		unless t.finished?
		    t.start = x if !t.start
		    t.stop = x
		end
	    end

	    if x > self.width
		new_width	= self.width * 2  
		resize(new_width, self.height)
	    end

	    if scrolling?
		view.ensure_visible(x, self.height / 2)
	    end
	end

	def new_event(time, generator, pending)
	    ping(time)

	    x	    = x_of(time)
	    line    = line_of(generator, x)
	    line.new_event(generator)
	    
	    y = (line.index + 0.2) * line_height
	    shape = Display::Style.event(generator, self, pending)
	    shape.move(x, y)

	    if y + line_height > self.height
		new_height	= self.height * 2 
		resize(self.width, new_height)
	    end

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
		@color_index = (@color_index + 1) % Display::Style::EVENT_COLORS.size
		Display::Style::EVENT_COLORS[@color_index]
	    end

	    def initialize(index)
		@index = index
		@colors = Hash.new
		@color_index = -1
	    end

	    def new_event(event)
	    end
	end

	class CanvasTask < CanvasLine
	    attr_reader :start, :stop
	    attr_reader :task, :display
	    # Task state: nil, :start, :success or :failed
	    attr_reader :state

	    TASK_STATES = [nil, :start, :stop, :success, :failed]

	    def finished?; state == :success || state == :failed end

	    def new_event(generator)
		new_state = generator.symbol.to_sym
		if TASK_STATES.index(new_state) && (TASK_STATES.index(new_state) > TASK_STATES.index(state))
		    @state = new_state
		    display.color = Display::Style::TASK_COLORS[new_state]
		end
	    end

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

		@display = Display::Style.task(task, display)
		@display.show
		@display.move(0, y)
	    end
	end


	def generator_calling(time, generator, context)
	    circle = new_event(time, generator, true) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, self)
	    end
	    
	    if source = event_source.delete(generator)
		raise unless event_display.has_key?(source)
		source = event_display[source]
		Display::Style.arrow(self) do |arrow|
		    arrow.start_point = [source.x, source.y]
		    arrow.end_point = [circle.x, circle.y]
		end

		Qt::CanvasLine.new(self) do |c|
		    c.set_points source.x, source.y, circle.x, circle.y
		    c.brush = Qt::Brush.new(Qt::Color.new(Display::Style::SIGNAL_COLOR))
		    c.pen = Qt::Pen.new(Qt::Color.new(Display::Style::SIGNAL_COLOR))
		    c.visible = true
		end
	    end
	end

	def generator_fired(time, event)
	    circle = new_event(time, event.generator, false) do |x, y|
		Qt::CanvasEllipse.new(line_height / 4, line_height / 4, self)
	    end
	    event_display[event] = circle
	end

	def generator_signalling(time, event, generator)
	    event_source[generator] = event
	end
    end
end


