require 'roby/task'

class Roby::Display::EventStructureServer
    class Task < Element
	attr_reader :width, :span, :group
	def initialize(task, column, display)
	    @group = Display::Style.task(task, display)
	    @width = @span = display.line_height * 0.5

	    super(column, display)
	end

	def color=(newcolor)
	    group.rectangle.color = newcolor
	end

	def update_width
	    @width = children.inject(display.event_spacing) { |x, event| x + event.width + display.event_spacing }
	    @span  = [group.title.bounding_rect.width, width].max

	    column.width = width * 1.2 if column && column.width < width
	    group.rectangle.set_size(width, group.rectangle.height)
	end

	def event_y; group.y + display.event_radius * 2 end

	# New event for this task. +event+ shall be an Event object.
	def event(new)
	    if !children.empty? && children.last.event.symbol == :stop
		children.insert(-2, new)
	    else
		children << new
	    end
	    new.column = nil
	    new.parent = self

	    update_width
	    move(group.x, group.y)
	end

	def move(x, y)
	    group.move(x, y)

	    children.inject(x = group.rectangle.x + display.event_spacing) do |x, event| 
		event.move(x + event.width / 2, event_y)
		x + event.width + display.event_spacing
	    end
	end
    end

    # (x, y) is the disc center
    class Event < Element
	attr_reader :event, :group
	def initialize(event, column, display)
	    @event = event
	    @group = Display::Style.event(event, display)
	    @watchers = []

	    super(column, display)
	end

	def width; [group.circle.width, group.title.bounding_rect.width].max end
	def span; width end

	def add_watch(&updater)
	    @watchers << updater
	end

	def move(x, y)
	    group.move(x, y)
	    @watchers.each { |w| w.call(x, y) }
	end
    end

    class TaskEvent < Event
	def initialize(ev, task, display)
	    @task = task
	    super(ev, task.column, display)
	end
    end
end

