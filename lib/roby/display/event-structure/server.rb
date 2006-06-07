require 'Qt'
require 'roby/support'
require 'roby/display/style'

module Roby
    # Displays the plan's causal network
    class EventStructureDisplayServer < Qt::Object
	MINWIDTH = 50

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
	    remaining.dup.enum_for(:each_with_index).
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
	    to.root.column ||= columns[0]
	    from.root.next_elements << to.root
	    from.root.propagate_column
   
	    # Offset columns if possible
	    offset_columns
	end

	def check_structure
	    # Check the continuity of task allocations
	    seen = Hash.new
	    each_column do |col|
		col.lines.each_with_index do |task, index|
		    next unless task
		    if allowed = seen[task]
			allowed_index, allowed_columns = allowed
			unless allowed_index == index && allowed_columns.include?(col) 
			    raise "error in column #{column_index(col)} for task #{task}: expected #{allowed_index} in columns #{allowed_columns.map { |c| column_index(c) }.sort.to_a.inspect}"
			end
		    else
			allowed_columns = col.inject([col]) do |allowed_columns, c| 
			    if c.lines[index]
				allowed_columns << c
			    else
				allowed_columns
			    end
			end
			seen[task] = [index, allowed_columns]
		    end
		end
	    end

	    # Check that element.column returns the right one
	    seen.each do |element, (_, allowed_columns)|
		if element.column != allowed_columns.first
		    raise 
		end
	    end
	end

	def offset_columns
	    dead, first = enum_for(:each_column).enum_cons(2).find { |empty, first| empty.empty? && !first.empty? }
	    if dead
	        offset = first.x - columns.first.x
		dead.next_column = nil
	        columns[0] = first
		raise if columns[1] == dead
		first.x -= offset
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

	def clear
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

require 'roby/display/event-structure/structure.rb'
require 'roby/display/event-structure/elements.rb'
    
