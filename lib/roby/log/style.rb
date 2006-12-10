module Qt
    [CanvasRectangle, CanvasEllipse, CanvasLine].each do |klass|
	klass.class_eval do
	    def color=(color)
		color ||= 'black'
		unless Qt::Color === color
		    color = Qt::Color.new(color)
		end
		self.brush = Qt::Brush.new(color)
		self.pen = Qt::Pen.new(color)
	    end
	end
    end
end

module Roby::Display::Style
    class CanvasGroup
	attr_reader :x, :y
	attr_reader :objects

	def initialize(args)
	    super()
	    @objects = args
	    @objects.each_key do |name| 
		singleton_class.send(:define_method, name) { objects[name] }
	    end
	    @x, @y = 0, 0
	end

	def position=(newpos)
	    @x, @y = *newpos
	end

	def [](name); @objects[name] end
	def move(x, y)
	    offset_x = x - @x
	    offset_y = y - @y
	    @x = x
	    @y = y
	    objects.each_value { |obj| obj.moveBy(offset_x, offset_y) }
	end
	def moveBy(dx, dy)
	    move(x + dx, y + dy)
	end
	def xmin; @objects.map { |_, o| o.x }.min end
	def xmax; @objects.map { |_, o| o.x + o.width }.max end
	def width; xmax - xmin end
	def ymin; @objects.map { |_, o| o.y }.min end
	def ymax; @objects.map { |_, o| o.y + o.height }.max end
	def height; ymax - ymin end

	def apply(name, *args); objects.each_value { |obj| obj.send(name, *args) if obj.respond_to?(name) } end
	def brush=(brush); apply(:brush=, brush) end
	def pen=(pen); apply(:pen=, pen) end
	def color=(color); apply(:color=, color) end
	def z=(z); apply(:z=, z) end
	def z; objects.find { true }.last.z end

	def show; apply(:show) end
	def hide; apply(:hide) end
	def visible?; @objects.enum_for(:each_value).any? { |o| o.visible? } end
	def visible=(flag); @objects.each_value { |o| o.visible = flag } end
    end

    
    TASK_COLORS = {
	nil => '#6DF3FF',
	:start => '#B0FFA6',
	:success => '#E2E2E2',
	:failed => '#E2A8A8',
	:finalized => '#000000'
    }
    TASK_Z = -1
    TASK_NAME_COLOR = 'black'
    TASK_FONTSIZE = 10

    ARROW_Z = 5
    ARROW_COLOR  = 'black'
    SIGNAL_COLOR = 'black'

    EVENT_COLOR  = 'black' # default color for events
    # [ light, dark ] array of colors for events
    EVENT_COLORS = [
	[ 'lightgrey', 'black' ],
	[ '#AFF6FF', '#4DD0FF' ]
    ]
    EVENT_Z = 1
    EVENT_FONTSIZE = 8

    PLAN_BASE_Z = -5
    PLAN_MIN_COLOR = [120, 255, 120]
    PLAN_MAX_COLOR = [120, 120, 255]

    def self.event(event, display, with_label = true)
	d = display.event_radius * 2
	circle = Qt::CanvasEllipse.new(d, d, display.canvas) do |e|
	    circle = e
	    e.z = EVENT_Z
	    e.color = EVENT_COLOR
	    e.visible = true
	end

	if !with_label
	    circle
	else
	    name = event.symbol if event.respond_to?(:symbol)
	    
	    title = Qt::CanvasText.new(name.to_s, display.canvas) do |t|
		title = t
		font = t.font
		font.pixel_size = EVENT_FONTSIZE
		t.font = font

		w = t.bounding_rect.width
		t.move(-w / 2, d / 2)
		t.z = EVENT_Z
		t.color = Qt::Color.new(TASK_NAME_COLOR)
		t.visible = true
	    end

	    CanvasGroup.new(:circle => circle, :title => title)
	end
    end

    def self.task_name(task)
	task_name = task.name.
	    gsub(/Roby::(?:Genom::)?/, '').
	    gsub(/!0x[0-9a-f]+/, '')
    end

    def self.task(task, display)
	rectangle = Qt::CanvasRectangle.new(0, 0, 0, display.line_height * 0.6, display.canvas) do |r|
	    r.color = TASK_COLORS[nil]
	    r.z	= TASK_Z
	    r.visible = true
	end

	title = Qt::CanvasText.new(task_name(task), display.canvas) do |t|
	    font = t.font
	    font.pixel_size = TASK_FONTSIZE
	    t.font = font

	    t.y = display.line_height * 0.6
	    t.color = Qt::Color.new(TASK_NAME_COLOR)
	    t.visible = true
	end

	CanvasGroup.new(:rectangle => rectangle, :title => title)
    end

    def self.arrow(display)
	line = Qt::CanvasLine.new(display.canvas) do |l|
	    l.set_points(0, 0, 0, 0)
	    l.pen = Qt::Pen.new(Qt::Color.new(ARROW_COLOR))
	    l.visible = true
	    l.z = ARROW_Z
	end
	yield(line) if block_given?

	line.create_arrow_end
	line
    end
end

class Qt::CanvasLine
    attr_accessor :arrow_end
    ARROW_END_SIZE  = 20 # arrow size in pixels
    ARROW_END_WIDTH = 44 # Arrow openness in degrees
    def create_arrow_end
	self.arrow_end = Qt::CanvasEllipse.new(ARROW_END_SIZE, ARROW_END_SIZE, self.canvas) do |e|
	    e.brush = Qt::Brush.new(self.pen.color)
	    e.visible = true
	    e.z = self.z
	end
	update_arrow_end
    end

    def pen=(new_pen)
	super(new_pen)
	if arrow_end
	    arrow_end.brush = Qt::Brush.new(new_pen.color)
	end
    end

    def update_arrow_end
	return unless arrow_end

	sx, sy, ex, ey = start_point.x, start_point.y, end_point.x, end_point.y
	dy, dx = [sy - ey, sx - ex]
	angle = Math.atan2(dy, dx) / Math::PI * 180

	arrow_end.move(ex, ey);
	arrow_end.set_angles(-(angle + ARROW_END_WIDTH / 2) * 16, ARROW_END_WIDTH * 16)
    end

    def end_point=(coord)
	new = [start_point.x, start_point.y, *coord]
	set_points(*new)
	update_arrow_end
    end
    def start_point=(coord)
	new = ([*coord] << end_point.x << end_point.y)
	set_points(*new)
	update_arrow_end
    end
    def visible=(flag)
	arrow_end.visible = flag if arrow_end
	super
    end
end

class Qt::CanvasText
    def height
	fm = Qt::FontMetrics.new(font)
	fm.bounding_rect(text).height
    end
    def width
	fm = Qt::FontMetrics.new(font)
	fm.bounding_rect(text).width
    end
end
