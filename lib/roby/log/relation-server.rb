require 'Qt'
require 'roby/support'
require 'roby/log/marshallable'
require 'roby/log/style'
require 'roby/log/dot'

require 'set'

module Roby::Display
    class RelationServer < Qt::Object
	MINWIDTH = 50

	attr_reader :line_height, :margin, :event_radius, :event_spacing, :dot_scale
	attr_reader :canvas, :view, :main_window
	attr_reader :events, :tasks, :relations
	attr_reader :canvas_tasks, :canvas_events, :canvas_arrows
	attr_reader :by_task

	BASE_LINES = 20
	def initialize(root_window)
	    super

	    # object_id => marshallable maps
	    @events = Hash.new
	    @tasks	= Hash.new
	    @relations	= Set.new

	    # a task_id => [event_id, ...] map
	    @by_task	= Hash.new { |h, k| h[k] = Set.new }

	    # canvas items for tasks, events and arrows
	    @canvas_tasks  = Hash.new # task_id => task_item
	    @canvas_events = Hash.new # event_id => event_item
	    @canvas_arrows = Hash.new # [event_id, event_id] => arrow_item

	    # Some graphical parameters
	    @line_height    = 40
	    @margin	    = 10
	    @event_radius   = 4
	    @event_spacing  = event_radius
	    @dot_scale	    = 0.7

	    # Qt objects
	    @canvas = Qt::Canvas.new(640, line_height * BASE_LINES + margin * 2)
	    @view   = Qt::CanvasView.new(@canvas, root_window)
	    @main_window = @view
	end

	class CanvasTask
	    attr_reader :canvas_item, :display, :events, :task_id
	    def initialize(task, display)
		@task_id     = task.source_id
		@canvas_item = Display::Style.task(task, display)
		# Put [0, 0] at the center of the item
		@canvas_item.move(-@canvas_item[:rectangle].width / 2, -@canvas_item[:rectangle].height / 2)
		@canvas_item.position = [0, 0]

		@display     = display
		@events	     = Hash.new
	    end

	    def task; display.tasks[task_id] end
	    def update; @canvas_item[:title].text = Display::Style.task_name(task); self end

	    def event(event)
		unless item = events[event.symbol]
		    item = events[event.symbol] = Display::Style.event(event, display)
		end

		layout
		item
	    end

	    def event_width
		events.map { |_, e| e.width }.max
	    end
	    def width
		(events.size - 1) * (event_width + display.event_spacing)
	    end
	    def color=(new_color); canvas_item[:rectangle].color = new_color end

	    def layout
		min_width = width
		if canvas_item[:rectangle].width < min_width
		    canvas_item[:rectangle].set_size(min_width, canvas_item[:rectangle].height)
		end

		spacing = event_width + display.event_spacing
		y = canvas_item[:rectangle].y + canvas_item[:rectangle].height / 3

		events = self.events.sort do |(x_symbol, x_ev), (y_symbol, y_ev)| 
		    if x_symbol == :start || y_symbol == :stop then -1
		    elsif x_symbol == :stop || y_symbol == :start then 1
		    else x_symbol.to_s <=> y_symbol.to_s
		    end
		end

		events.inject(canvas_item[:rectangle].x) do |x, (_, ev)|
		    ev.move(x, y)
		    x + spacing
		end
	    end

	    def move(x, y)
		offset_x, offset_y = x - canvas_item.x, y - canvas_item.y
		canvas_item.move(x, y)
		events.each { |_, ev| ev.moveBy(offset_x, offset_y) }
	    end
	end

	def canvas_task(task)
	    if !(canvas_item = canvas_tasks[task.source_id])
		canvas_item = canvas_tasks[task.source_id] = CanvasTask.new(task, self)
		each_event(task) do |ev|
		    canvas_item.event(ev)
		end
	    end

	    canvas_item
	end
	def canvas_arrow(from, to)
	    arrow = (canvas_arrows[ [from.source_id, to.source_id] ] ||= Display::Style.arrow(self))

	    arrow.start_point = relation_object_pos(from.source_id)
	    arrow.end_point   = relation_object_pos(to.source_id)
	end

	def state_change(task, symbol)
	    task_item = canvas_task(task)
	    task_item.color = Display::Style::TASK_COLORS[symbol]
	    changed!
	end

	def each_event(task, &iterator)
	    source_id = task.source_id if task
	    by_task[source_id].each { |id| yield(events[id]) }
	end
	def each_task(&iterator)
	    tasks.each_value(&iterator)
	end
	def each_relation(&iterator)
	    relations.each { |f, t| yield(relation_object(f), relation_object(t)) }
	end

	def task(task)
	    tasks[task.source_id] = task
	    canvas_task(task)
	end

	def event(gen)
	    events[gen.source_id] = gen
	    if gen.respond_to?(:task)
		task_id = gen.task.source_id

		tasks[task_id] = gen.task
		canvas_task(gen.task).
		    update.
		    event(gen)
	    end
	    by_task[task_id] << gen.source_id
	end

	def added_relation(time, from, to)
	    relations << [from.source_id, to.source_id]
	    define_relation_object(from)
	    define_relation_object(to)
	    changed!
	end
	def removed_relation(time, from, to)
	    relations.delete( [from.source_id, to.source_id] )
	    changed!
	end

	def task_initialize(time, task, start, stop)
	    task(task)
	    event(start)
	    event(stop)
	    changed!
	end

	def next_id
	    @id ||= 0
	    @id += 1
	end
	def layout
	    DotLayout.layout(self, dot_scale)
	end
	alias :timer_update :layout
    end
end

