require 'Qt'
require 'roby/support'
require 'roby/display/style'
require 'roby/task'

module Roby
    # Displays the plan's causal network
    class EventStructureDisplayServer < Qt::Object
	class Column
	    attr_reader :x, :index, :width, :display, :lines
	    def initialize(x, idx, display)
		@display = display
		@x	= x
		@width  = 0
		@index	= idx
		@lines	= []
	    end

	    def width=(new)
		offset = new - width
		@width = new
		display.columns.each_with_index do |col, idx|
		   next if idx <= index 
		   next unless col
		   col.x += offset
		end
	    end

	    def x=(new)
		offset = new - x
		@x = x

		lines.compact.each do |task|
		    task.move(task.x + offset, task.y)
		end
	    end

	    def add(task)
		line = if old_idx = lines.index(task)
			   old_idx
		       else
			   idx = lines.index(nil) || lines.size
			   lines[idx] = task
			   idx
		       end

		task.move(x, display.margin + line * display.line_height)
	    end

	    def remove(task)
		return unless old_idx = lines.index(task)
		lines[old_idx] = nil
	    end
	end
	
	class Task
	    attr_reader :column, :events, :display
	    attr_reader :x, :y
	    def initialize(column, task, display)
		@rectangle, @title = DisplayStyle.task(task, display)
		@display = display
		@events  = []
		@x, @y = 0, 0

		self.column = column
	    end

	    def update_width
		w = column.width
		needed = events.size * (display.event_radius * 2 + display.event_spacing)
		if w < needed
		    column.width = needed * 1.2
		end

		@rectangle.set_size(needed, @rectangle.height)
	    end

	    # New event for this task. +event+ shall be an Event object.
	    def event(event)
		events << event
		update_width

		x = @rectangle.x + (events.size - 0.5) * (display.event_spacing + display.event_radius * 2)
		event.move(x, @rectangle.y + @rectangle.height / 2)
	    end

	    def column=(new)
		return if new == column
		if column
		    raise if new.index < column.index
		    column.remove(self)
		end
		@column = new

		update_width
		column.add(self)
	    end
	    
	    def move(x, y)
		@rectangle.moveBy(x - self.x, y - self.y)
		@title.moveBy(x - self.x, y - self.y)
		@x, @y = x, y

		left_margin = @rectangle.x + display.event_spacing / 2 + display.event_radius
		x_step	    = display.event_spacing + display.event_radius * 2
		y	    = @rectangle.y + @rectangle.height / 2
		events.each_with_index do |ev, idx|
		    ev.move(left_margin + idx * x_step, y)
		end
	    end
	end

	class Event
	    def initialize(event, display)
		@shape = DisplayStyle.event(event, display)
		@watchers = []
	    end

	    attr_reader :shape
	    def add_watch(&updater)
		@watchers << updater
	    end

	    def move(x, y)
		@watchers.each do |w|
		    w.call(x, y)
		end
		@shape.move(x, y)
	    end
	end
	
	class TaskEvent < Event
	    def initialize(ev, task, display)
		super(ev, display)
		@task = task

	    end
	    attr_accessor :task
	    def column; task.column end
	    def column=(new); task.column = new end
	end
	
	class StandaloneEvent < Event
	    attr_reader :column
	    def column=(new)
		return if new == column
		if column
		    raise if new.index < column.index
		    column.remove(self)
		end
		@column = new
		column.add(self)
	    end
	end
	
	attr_reader :event_color, :task_color
	attr_reader :line_height, :margin, :event_radius, :event_spacing
	attr_reader :canvas, :view, :main_window
	attr_reader :columns, :tasks, :events

	BASE_LINES = 20
	def initialize
	    super

	    @start_time	    = nil # start time (time of the first event)
	    @line_height    = 30  # height of a line in pixel
	    @tasks	    = Hash.new # a Roby::Task -> Display::Task map
	    @events	    = Hash.new # a Roby::Event -> Display::Event map
	    @columns	    = []
	    @margin	    = 10
	    @event_radius   = line_height / 4
	    @event_spacing  = event_radius

	    @task_color = 'lightblue'
	    @event_color = 'lightgreen'

	    @canvas = Qt::Canvas.new(640, line_height * BASE_LINES + margin * 2)
	    @view   = Qt::CanvasView.new(@canvas, nil)
	    @main_window = @view
	end

	def column(index)
	    if col = columns[index]
		col
	    else
		x = columns.
		    select { |c| c.index < index }.
		    map { |c| c.width }.
		    inject(0) { |a, b| a + b }

		columns[index] = Column.new(margin + x, index, self) 
	    end
	end
	def task(task);	    @tasks[task] ||= Task.new(column(0), task, self) end

	def add(ev_from, ev_to)
	    # Build canvas objects
	    from = event(ev_from)
	    to   = event(ev_to)

	    # Reorder objects in columns
	    base_column = (from.column ||= column(0))
	    to.column   = column(from.column.index + 1) unless (to.column && to.column.index > from.column.index)

	    # Create the link and add updaters in both events
	    line = DisplayStyle.arrow(from.shape.x, from.shape.y, to.shape.x, to.shape.y, self)
	    from.add_watch { line.set_points(from.shape.x, from.shape.y, line.end_point.x, line.end_point.y) }
	    to.add_watch { line.set_points(line.start_point.x, line.start_point.y, to.shape.x, to.shape.y) }
	end

	# def delete(from, to)
	# end

	# def wipe(event)
	# end

	def event(ev)
	    return events[ev] if events[ev]
		
	    if ev.respond_to?(:task)
		task = task(ev.task)
		events[ev] ||= TaskEvent.new(ev, task, self)
		task.event(events[ev])
	    else
		events[ev] ||= StandaloneEvent.new(ev, self)
		events[ev].column = column(0)
	    end

	    events[ev]
	end
    end
end
    
