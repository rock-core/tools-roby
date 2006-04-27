module Roby
    module DisplayStyle
	TASK_COLOR = '#B0FFA6'
	TASK_Z = -1
	TASK_NAME_COLOR = 'black'
	TASK_FONTSIZE = 10

	SIGNAL_COLOR = 'black'
	ARROW_COLOR  = 'black'
	EVENT_COLOR  = 'black' # default color for events
	# [ light, dark ] array of colors for events
	EVENT_COLORS = [
	    [ 'lightgrey', 'black' ],
	    [ '#AFF6FF', '#4DD0FF' ]
	]
	EVENT_Z = 1
	EVENT_FONTSIZE = 8

	def self.event(event, display)
	    d = display.event_radius * 2
	    circle = Qt::CanvasEllipse.new(d, d, display.canvas) do |e|
		circle = e
		e.z = EVENT_Z
		e.brush = Qt::Brush.new(Qt::Color.new(EVENT_COLOR))
		e.visible = true
	    end

	    name = event.model.symbol if event.model.respond_to?(:symbol)
	    
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

	    [circle, title]
	end

	def self.task(task, display)
	    rectangle = Qt::CanvasRectangle.new(0, 0, 0, display.line_height * 0.6, display.canvas) do |r|
		r.brush = Qt::Brush.new(Qt::Color.new(TASK_COLOR))
		r.pen   = Qt::Pen.new(Qt::Color.new(TASK_COLOR))
		r.z	= TASK_Z
		r.visible = true
	    end

	    title = Qt::CanvasText.new(task.model.name.gsub(/Roby::(?:Genom::)?/, ''), display.canvas) do |t|
		font = t.font
		font.pixel_size = TASK_FONTSIZE
		t.font = font

		t.y = display.line_height * 0.6
		t.color = Qt::Color.new(TASK_NAME_COLOR)
		t.visible = true
	    end

	    [rectangle, title]
	end

	ARROW_Z = 5
	ARROWEND_SIZE  = 20 # arrow size in pixels
	ARROWEND_WIDTH = 44 # Arrow openness in degrees
	def self.arrow(fx, fy, tx, ty, display)
	    line = Qt::CanvasLine.new(display.canvas) do |l|
		l.set_points(fx, fy, tx, ty)
		l.pen = Qt::Pen.new(Qt::Color.new(ARROW_COLOR))
		l.visible = true
		l.z = ARROW_Z
	    end

	    # end of arrow
	    arrowend = Qt::CanvasEllipse.new(ARROWEND_SIZE, ARROWEND_SIZE, display.canvas) do |e|
		e.brush = Qt::Brush.new(Qt::Color.new(ARROW_COLOR))
		e.visible = true
		e.z = ARROW_Z
	    end

	    arrow_update = lambda do |sx, sy, ex, ey|
		dy, dx = [sy - ey, sx - ex]
		angle = Math.atan2(dy, dx) / Math::PI * 180

		n = Math.sqrt(dx * dx + dy * dy)

		arrowend.move(ex + dx / n * display.event_radius, ey + dy / n * display.event_radius)
		arrowend.set_angles(-(angle + ARROWEND_WIDTH / 2) * 16, ARROWEND_WIDTH * 16)
	    end
	    line.watchers << arrow_update
	    arrow_update.call(line.start_point.x, line.start_point.y, line.end_point.x, line.end_point.y)

	    line
	end
    end
end

class Qt::CanvasLine
    attribute(:watchers) { Set.new }
    def end_point=(coord)
	new = [start_point.x, start_point.y, *coord]
	set_points(*new)
	watchers.each { |w| w.call(*new) }
    end
    def start_point=(coord)
	new = ([*coord] << end_point.x << end_point.y)
	set_points(*new)
	watchers.each { |w| w.call(*new) }
    end
end

