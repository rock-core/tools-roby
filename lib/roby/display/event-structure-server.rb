require 'Qt'
require 'roby/support'
require 'roby/display/style'
require 'roby/task'

module Roby
    # Displays the plan's causal network
    class EventStructureDisplayServer < Qt::Object
	MINWIDTH = 50
	
	class Column
	    attr_reader :x, :width, :display, :lines
	    def initialize(x, display)
		@display = display
		@x	= x
		@lines	= []

		@width = MINWIDTH
	    end

	    attr_accessor :next_column
	    def each(&iterator)
		if next_column
		    yield(self.next_column)
		    next_column.each(&iterator)
		end
		self
	    end
	    def each_line(&iterator); lines.each(&iterator) end
	    def parent_of?(c); !!find { |child| child == c } end
	    include Enumerable

	    def empty?; lines.all? { |l| !l } end

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
			    column.remove(element)
			else
			    remaining -= column.width
			end
		    end
		end

		display.update_canvas_width
	    end

	    def x=(new)
		offset = new - x
		@x = new

		lines.compact.each do |element|
		    element.move(element.x + offset, element.y) if element.column == self
		end
	    end

	    def add(element)
		if element.width > width
		    self.width = element.width * 1.2
		end
		raise if lines.index(element)

		line_idx = (0..(lines.size - 1)).find do |line_idx|
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
			    display.remaining[index] = [nil, 0] if !next_column
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

	    def remove(element, line_idx = nil)
		return unless (line_idx ||= lines.index(element))
		return if lines[line_idx] != element

		lines[line_idx] = nil
		if next_column
		    next_column.remove(element, line_idx)
		elsif display.remaining[line_idx].first == element
		    display.remaining[line_idx] = [nil, 0]
		end
	    end
	end

	class Element
	    attr_reader :column, :next_elements, :display
	    def initialize(column, display)
		@display	= display
		@next_elements	= Set.new
		@parent		= nil
		@children	= Array.new

		self.column = column
	    end

	    def x; group.x end
	    def y; group.y end

	    def column=(new)
		column_update(new)
		propagate_column if column
		new
	    end

	    def column_update(new)
		raise "trying to set the column of a non-root element" if parent
		if column
		    column.remove(self)
		    # check that nothing is broken ...
		    display.each_column { |c| raise if c.lines.index(self) }
		end

		@column = new
		new.add(self) if new
	    end

	    def propagate_column
		seen = Set.new
		seen << self
		enum_bfs(:each_following_element).each_edge do |from, to|
		    next if seen.include?(to)
		    seen << to
		    next_column = (from.column.next_column || display.newcolumn)
		    to.column_update(next_column) unless next_column.parent_of?(to.column)
		end
	    end
	    def each_following_element(&iterator)
		next_elements.each(&iterator)
	    end

	    protected :column_update

	    attr_accessor :parent
	    attr_reader   :children
	    def root; parent || self end
	    def child(element)
		element.column = nil
		element.parent = self
		children << element
	    end
	end
	
	class Task < Element
	    attr_reader :width, :span, :group
	    def initialize(task, column, display)
		@group = DisplayStyle.task(task, display)
		@width = @span = display.line_height * 0.5

		super(column, display)
	    end

	    def color=(newcolor)
		group.rectangle.color = newcolor
	    end

	    def update_width
		@width = children.inject(x = display.event_spacing) { |x, event| x + event.width + display.event_spacing }
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
		@group = DisplayStyle.event(event, display)
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
	
	attr_reader :line_height, :margin, :event_radius, :event_spacing
	attr_reader :canvas, :view, :main_window
	attr_reader :tasks, :events, :remaining, :columns
	attr_reader :event_filters, :arrows

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
	    @arrows	    = Hash.new

	    first_column = Column.new(margin, self)
	    @columns	    = [first_column, first_column] # [first, last] column objects
	    @remaining	    = []

	    @canvas = Qt::Canvas.new(640, line_height * BASE_LINES + margin * 2)
	    @view   = Qt::CanvasView.new(@canvas, nil)
	    @main_window = @view
	    
	    @event_filters = [ lambda { |ev| ev.symbol == :aborted } ]
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

	    # Allocate the elements which were spanning outside the last column
	    # It will update the 'remaining' array
	    remaining.enum_for(:each_with_index).
		select { |(task, _), _| task }.
		each { |(task, w), line_idx| new.allocate(line_idx, task, w) }

	    columns.last.next_column = new
	    columns[1] = new
	end

	def needed_canvas_width
	    w = remaining.map { |_, w| w }.max || 0
	    w += columns[0].inject(margin + columns[0].width) { |x, col| x + col.width }
	end

	def update_canvas_width
	    needed = needed_canvas_width
	    if canvas.width < needed
		canvas.resize(canvas.width * 2, canvas.height)
	    end
	end

	def task(task)
	    @tasks[task] ||= Task.new(task, columns.first, self) 
	end

	def column_index(column)
	    if cidx = enum_for(:each_column).enum_for(:each_with_index).
		find { |c, _| c == column }
		cidx.last
	    end
	end

	def add(ev_from, ev_to)
	    if event_filters.find { |f| f[ev_from] } || event_filters.find { |f| f[ev_to] }
		return
	    end
	    changed!

	    
	    # Build canvas objects
	    from, to = event(ev_from), event(ev_to)

	    # Create the link and add updaters in both events
	    line = DisplayStyle.arrow(from.x, from.y, to.x, to.y, self)
	    arrows[ [from, to] ] = line
	    from.add_watch  { line.start_point = [from.x, from.y] }
	    to.add_watch    { line.end_point = [to.x, to.y] }
	    
	    # Reorder objects in columns
	    base_column = (from.root.column ||= columns[0])
	    from.root.next_elements << to.root
	    from.root.propagate_column
   
	    # Offset columns if possible
	    offset_columns
	end

	def offset_columns
	    dead, first = enum_for(:each_column).enum_cons(2).find { |empty, first| empty.empty? && !first.empty? }
	    if dead
	        offset = first.x - columns.first.x
		dead.next_column = nil
	        columns[0] = first

	        each_column { |col| col.x -= offset }
	    end
	end

	PreferredLine = Struct.new :index, :count, :forbidden
	def reorder_lines
	    preferred = Hash.new { |h, k| h[k] = PreferredLine.new(0, 0, []) }
	    columns[0].each do |col|
		col.lines.each_with_index do |task, line_idx|
		    next unless task
		    preferred[task].index += line_idx
		    preferred[task].count += 1
		    preferred[task].forbidden << line_idx
		end
	    end
	end

	def start(roby_task)
	    changed!
	    task = task(roby_task)
	    task.color = DisplayStyle::TASK_COLORS[:running]
	end

	def success(roby_task)
	    changed!
	    task = task(roby_task)
	    task.color = DisplayStyle::TASK_COLORS[:success]
	end
	def failed(roby_task)
	    changed!
	    task = task(roby_task)
	    task.color = DisplayStyle::TASK_COLORS[:failed]
	end

	def delete(ev_from, ev_to)
	    from, to = event(ev_from), event(ev_to)
	    arrows[ [from, to] ].hide if arrows.has_key? [from, to]
	end

	# def wipe(event)
	# end

	def event(ev)
	    return events[ev] if events[ev]

	    if event_filters.find { |f| f[ev] }
		return
	    end
		
	    changed!
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
    
