require 'Qt'
require 'roby/support'
require 'roby/display/style'
require 'roby/task'

module Roby
    # Displays the plan's causal network
    class EventStructureDisplayServer < Qt::Object
	class Column
	    attr_reader :x, :width, :display, :lines
	    def initialize(x, display)
		@display = display
		@x	= x
		@width  = 0
		@lines	= []
	    end

	    attr_accessor :next_column
	    def each(&iterator)
		if next_column
		    yield(self.next_column)
		    next_column.each(&iterator)
		end
		self
	    end
	    def parent_of?(c); !!find { |child| child == c } end
	    include Enumerable

	    def width=(new)
		offset = new - width
		@width = new

		# Adjust column positions
		each { |col| col.x += offset }
		
		# Adjust spanning
		lines.each_with_index do |element, line_idx|
		    next unless element
		    remaining = element.span - width

		    each do |column|
			break if column.lines[line_idx] != element
			
			if remaining <= 0
			    column.lines[line_idx] = nil
			else
			    remaining -= column.width
			end
		    end
		end
	    end

	    def x=(new)
		offset = new - x
		@x = new

		lines.compact.each do |element|
		    element.move(element.x + offset, element.y)
		end
	    end

	    def add(element)
		if element.width > width
		    self.width = element.width * 1.2
		end

		line_idx = (1..lines.size).find do |line_idx|
		    allocate(line_idx, element, element.span)
		end

		unless line_idx
		    line_idx = lines.size
		    display.newline
		    allocate(line_idx, element, element.span)
		end
		
		element.move(x, display.margin + line_idx * display.line_height)
	    end

	    def allocate(index, element, span)
		return if lines[index]

		remaining = span - width
		found = if remaining <= 0
			    true
			elsif !next_column
			    display.remaining[index] = [element, remaining]
			    true
			else
			    next_column.allocate(index, element, remaining)
			end

		if found
		    lines[index] = element
		    true
		end
	    end

	    def remove(element)
		return unless line_idx = lines.index(element)
		lines[line_idx] = nil
		next_column.remove(element) if next_column
	    end
	end

	class Element
	    attr_reader :column, :next_elements, :display
	    def initialize(column, display)
		@display	= display
		@next_elements	= Set.new

		self.column = column
	    end

	    def column=(new)
		column.remove(self) if column

		@column = new
		new.add(self)

		unless next_elements.empty?
		    next_column = (new.next_column || display.newcolumn)
		    next_elements.each do |element|
			element.column = next_column
		    end
		end
	    end
	end
	
	class Task < Element
	    attr_reader :events
	    attr_reader :x, :y, :width, :span
	    def initialize(task, column, display)
		@rectangle, @title = DisplayStyle.task(task, display)
		@events  = []
		@x, @y = 0, 0
		@width = @span = display.line_height * 0.5

		super(column, display)
	    end

	    def update_width
		@width = events.inject(x = display.event_spacing) { |x, event| x + event.width + display.event_spacing }
		@span  = [@title.bounding_rect.width, width].max
		
		column.width = width * 1.2 if column && column.width < width
		@rectangle.set_size(width, @rectangle.height)
	    end

	    def event_y; @rectangle.y + display.event_radius * 2 end

	    # New event for this task. +event+ shall be an Event object.
	    def event(new)
		if !events.empty? && events.last.event.symbol == :stop
		    events.insert(-2, new)
		else
		    events << new
		end

		update_width
		move(self.x, self.y)
	    end
    
	    def move(x, y)
		offset = [x - self.x, y - self.y]
		@rectangle.moveBy(*offset)
		@title.moveBy(*offset)
		@x, @y = x, y

		events.inject(x = @rectangle.x + display.event_spacing) do |x, event| 
		    event.move(x + event.width / 2, event_y)
		    x + event.width + display.event_spacing
		end
	    end
	end

	# (x, y) is the disc center
	class Event < Element
	    def initialize(event, column, display)
		@circle, @text = DisplayStyle.event(event, display)
		@watchers = []

		super(column, display)
	    end
	    
	    def x; @circle.x end
	    def y; @circle.y end
	    def width; [@circle.width, @text.bounding_rect.width].max end
	    def span; width end

	    def add_watch(&updater)
		@watchers << updater
	    end

	    def move(x, y)
		offset = [x - self.x, y - self.y]
		@x, @y = x, y

		@circle.moveBy(*offset)
		@text.moveBy(*offset)
		
		@watchers.each { |w| w.call(x, y) }
	    end
	end
	
	class TaskEvent < Event
	    def initialize(ev, task, display)
		@task = task
		super(ev, task.column, display)
	    end
	    attr_accessor :task
	    def column; task.column end
	    def column=(new); task.column = new end
	end
	
	attr_reader :line_height, :margin, :event_radius, :event_spacing
	attr_reader :canvas, :view, :main_window
	attr_reader :tasks, :events, :remaining, :columns

	BASE_LINES = 20
	def initialize
	    super

	    @start_time	    = nil # start time (time of the first event)
	    @line_height    = 40  # height of a line in pixel
	    @margin	    = 10
	    @event_radius   = 4
	    @tasks	    = Hash.new # a Roby::Task -> Display::Task map
	    @events	    = Hash.new # a Roby::Event -> Display::Event map
	    @event_spacing  = event_radius

	    first_column = Column.new(margin, self)
	    @columns	    = [first_column, first_column] # [first, last] column objects
	    @remaining	    = []

	    @canvas = Qt::Canvas.new(640, line_height * BASE_LINES + margin * 2)
	    @view   = Qt::CanvasView.new(@canvas, nil)
	    @main_window = @view

	    newcolumn
	end

	def each_column(&iterator)
	    if columns.first
		yield(columns.first)
		columns.first.each(&iterator)
	    end
	    self
	end

	def newline
	    each_column { |c| c.lines << nil }
	    remaining << [nil, 0]
	end

	def newcolumn
	    x = columns[0].inject(margin + columns[0].width) { |x, col| x + col.width }
	    new = Column.new(x, self) 

	    remaining.enum_for(:each_with_index).
		select { |(task, _), _| task }.
		each { |(task, w), line_idx| new.allocate(line_idx, task, task.span) }

	    columns.last.next_column = new
	    columns[1] = new
	end

	def task(task)
	    @tasks[task] ||= Task.new(task, columns.first, self) 
	end

	def column_index(column)
	    enum_for(:each_column).enum_for(:each_with_index).
		find { |c, _| c == column }.last
	end

	def add(ev_from, ev_to)
	    # Build canvas objects
	    from = event(ev_from)
	    to   = event(ev_to)

	    # Reorder objects in columns
	    base_column = (from.column ||= columns[0])
	    unless to.column && base_column.parent_of?(to.column)
		to.column = (from.column.next_column || newcolumn)
		from.next_elements << to
	    end

	    # Create the link and add updaters in both events
	    line = DisplayStyle.arrow(from.x, from.y, to.x, to.y, self)
	    from.add_watch  { line.start_point = [from.x, from.y] }
	    to.add_watch    { line.end_point = [to.x, to.y] }
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
		events[ev] ||= Event.new(ev, columns[0], self)
	    end

	    events[ev]
	end
    end
end
    
