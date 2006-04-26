module Roby
    module DisplayStyle
	TASK_COLOR = '#B0FFA6'
	TASK_Z = -1
	TASK_NAME_COLOR = 'black'

	SIGNAL_COLOR = 'black'
	ARROW_COLOR  = 'black'
	EVENT_COLOR  = 'black' # default color for events
	# [ light, dark ] array of colors for events
	EVENT_COLORS = [
	    [ 'lightgrey', 'black' ],
	    [ '#AFF6FF', '#4DD0FF' ]
	]
	EVENT_Z = 1

	def self.event(event, display)
	    Qt::CanvasEllipse.new(display.line_height / 4, display.line_height / 4, display.canvas) do |e|
		yield(e) if block_given?
		e.z = EVENT_Z
		e.visible = true
		e.brush = Qt::Brush.new(Qt::Color.new(EVENT_COLOR))
	    end
	end

	def self.task(task, display)
	    rectangle = Qt::CanvasRectangle.new(0, 0, 0, display.line_height * 0.4, display.canvas) do |r|
		r.brush = Qt::Brush.new(Qt::Color.new(TASK_COLOR))
		r.pen   = Qt::Pen.new(Qt::Color.new(TASK_COLOR))
		r.z	= TASK_Z
		r.visible = true
	    end

	    title = Qt::CanvasText.new(task.model.name.gsub(/Roby::(?:Genom::)?/, ''), display.canvas) do |t|
		t.y = display.line_height * 0.4
		t.color = Qt::Color.new(TASK_NAME_COLOR)
		t.visible = true
	    end

	    [rectangle, title]
	end

	def self.arrow(fx, fy, tx, ty, display)
	    line = Qt::CanvasLine.new(display.canvas) do |line|
		yield(line) if block_given?
		line.set_points(fx, fy, tx, ty)
		line.pen = Qt::Pen.new(Qt::Color.new(ARROW_COLOR))
		line.visible = true
	    end
	end
    end
end


