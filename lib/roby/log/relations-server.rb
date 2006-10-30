require 'Qt'
require 'roby/support'
require 'roby/log/marshallable'
require 'roby/log/style'
require 'roby/log/dot'
require 'facet/time/elapse'
require 'utilrb/time/to_hms'

require 'set'

class Qt::Canvas
    def clear
	all_items.each { |item| item.dispose }
	update
    end
end

module Roby::Display
    class CanvasTask
	MINWIDTH = 50

	attr_reader :canvas_item, :display, :events, :task_id
	def initialize(task, display)
	    @task_id     = task.source_id
	    @canvas_item = Style.task(task, display)
	    # Put [0, 0] at the center of the item
	    @canvas_item.move(-@canvas_item[:rectangle].width / 2, -@canvas_item[:rectangle].height / 2)
	    @canvas_item.position = [0, 0]

	    @display     = display
	    @events	     = Hash.new
	    layout
	end

	def task; display.tasks[task_id] end
	def update; @canvas_item[:title].text = Style.task_name(task); self end

	def event(event)
	    unless item = events[event.symbol]
		item = events[event.symbol] = Style.event(event, display)
		item.visible = self.visible?
	    end

	    layout
	    item
	end

	def event_width
	    events.map { |_, e| e.width }.max || 0
	end
	def width
	    [(events.size - 1) * (event_width + display.event_spacing), MINWIDTH].max
	end
	def color=(new_color); canvas_item[:rectangle].color = new_color end

	def layout
	    min_width = width
	    if canvas_item[:rectangle].width < min_width
		canvas_item[:rectangle].set_size(min_width, canvas_item[:rectangle].height)
	    end

	    init, spacing = if events.size > 1
				[0, [event_width + display.event_spacing, width / (events.size - 1)].max]
			    else
				[width / 2, 0]
			    end

	    y = canvas_item[:rectangle].y + canvas_item[:rectangle].height / 3

	    events = self.events.sort do |(x_symbol, x_ev), (y_symbol, y_ev)| 
		if x_symbol == :start || y_symbol == :stop then -1
		elsif x_symbol == :stop || y_symbol == :start then 1
		else x_symbol.to_s <=> y_symbol.to_s
		end
	    end

	    events.inject(canvas_item[:rectangle].x + init) do |x, (_, ev)|
		ev.move(x, y)
		x + spacing
	    end
	end

	def visible?; canvas_item.visible?  end
	def visible=(flag)
	    canvas_item.visible = flag 
	    events.each { |_, ev| ev.visible = flag }
	end

	def x; canvas_item.x end
	def y; canvas_item.y end
	def height; canvas_item.height * 2 end
	def move(x, y)
	    offset_x, offset_y = x - canvas_item.x, y - canvas_item.y
	    canvas_item.move(x, y)
	    events.each { |_, ev| ev.moveBy(offset_x, offset_y) }
	end
    end


    class RelationServer < Qt::Object
	include DRbDisplayMixin

	attr_reader :line_height, :margin, :event_radius, :event_spacing, :dot_scale
	attr_reader :canvas, :view, :main_window
	attr_reader :events, :tasks, :task_relations, :event_relations
	attr_reader :canvas_tasks, :canvas_events, :canvas_arrows, :canvas_plans
	attr_reader :by_task
	attr_reader :task_states
	attr_reader :plans

	BASE_LINES = 20
	def initialize(root_window)
	    super

	    # Some graphical parameters
	    @line_height    = 40
	    @margin	    = 10
	    @event_radius   = 4
	    @event_spacing  = event_radius
	    @dot_scale	    = 1
	    @colors	    = Hash.new

	    # Qt objects
	    @canvas = Qt::Canvas.new(640, line_height * BASE_LINES + margin * 2)

	    @main_window = Qt::Widget.new(root_window)
	    toplevel_layout = Qt::VBoxLayout.new(@main_window)

	    buttonbar = Qt::HBoxLayout.new(@main_window)
	    toplevel_layout.add_layout(buttonbar)

	    relayout       = Qt::PushButton.new("Redo layout", @main_window)
	    @show_finished  = Qt::PushButton.new("Finished", @main_window)
	    @show_finished.toggle_button = true
	    @show_finished.on = true
	    @show_finalized = Qt::PushButton.new("Finalized", @main_window)
	    @show_finalized.toggle_button = true

	    connect(relayout, SIGNAL('pressed()'), self, SLOT('layout()'))
	    connect(@show_finished, SIGNAL('toggled(bool)'), self, SLOT('update_task_show()'))
	    connect(@show_finalized, SIGNAL('toggled(bool)'), self, SLOT('update_task_show()'))
	    buttonbar.add_widget(relayout)
	    buttonbar.add_widget(@show_finished)
	    buttonbar.add_widget(@show_finalized)

	    @view      = Qt::CanvasView.new(@canvas, @main_window)
	    toplevel_layout.add_widget(@view)

	    clear
	end

	def each_plan
	    seen_tasks = ValueSet.new
	    plans.each do |obj, tasks|
		seen_tasks |= tasks
		yield(obj, tasks)
	    end

	    free_tasks = (tasks.values.to_value_set - seen_tasks)
	    yield(0, free_tasks) unless free_tasks.empty?
	end

	attr_reader :colors
	def colors=(color_map)
	    @colors = color_map.inject({}) do |pens, (rel, color)|
	        pens[rel] = Qt::Pen.new(Qt::Color.new(color || 'black'))
	        pens
	    end
	end

	def clear
	    @canvas.clear

	    # object_id => marshallable maps
	    @events		= Hash.new
	    @tasks		= Hash.new
	    @plans		= Hash.new
	    @task_relations	= Set.new
	    @event_relations	= Set.new
	    @task_states	= Hash.new
	    @plans		= Hash.new { |h, k| h[k] = [] }

	    # a task_id => [event_id, ...] map
	    @by_task	= Hash.new { |h, k| h[k] = Set.new }

	    # canvas items for tasks, events and arrows
	    @canvas_tasks  = Hash.new # task_id => task_item
	    @canvas_events = Hash.new # event_id => event_item
	    @canvas_arrows = Hash.new # [event_id, event_id] => arrow_item
	    @canvas_plans  = Array.new # array of rectangles

	    changed!
	end

	# Returns or builds the canvas item for +task+
	def canvas_task(task)
	    if !(canvas_item = canvas_tasks[task.source_id])
		canvas_item = canvas_tasks[task.source_id] = CanvasTask.new(task, self)
		each_event(task) do |ev|
		    canvas_item.event(ev)
		end
	    end

	    canvas_item
	end

	def canvas_plan(x0, y0, x1, y1)
	    item = Qt::CanvasRectangle.new(x0, y0, x1 - x0, y1 - y0, canvas) do |r|
		r.brush = Qt::Brush.new Qt::Brush::NoBrush
		r.pen = Qt::Pen.new Qt::Color.new('black')
		r.visible = true
		r.z = 10
	    end
	    canvas_plans << item
	end

	# Returns the reference position for +event_id+
	def event_pos(event_id)
	    event = events[event_id]
	    canvas_item = if event.respond_to?(:task)
			      canvas_task(event.task).event(event)
			  else canvas_events[event_id]
			  end

	    [canvas_item.x, canvas_item.y]
	end

	# Builds or updates the from -> to arrow, where from and to are events
	def canvas_event_arrow(kind, from, to)
	    arrow, from_pos, to_pos = relation_node_info(kind, from, to, &method(:event_pos))
	    if !(u = unit_vector(from_pos, to_pos))
		arrow.start_point = from_pos
		arrow.end_point = to_pos
		return
	    end

	    arrow.start_point = from_pos.zip(u).map { |from_pos, d| from_pos + d * event_radius }
	    arrow.end_point   = to_pos.zip(u).map { |to_pos, d| to_pos - d * event_radius }
	    arrow.visible = !(hidden?(from) || hidden?(to))
	end

	# Returns the reference position for +task_id+
	def task_pos(task_id)
	    canvas_item = canvas_task(tasks[task_id]).canvas_item[:rectangle]
	    [canvas_item.x + canvas_item.width / 2, canvas_item.y + canvas_item.height / 2]
	end

	# Returns the unit vector from -> to
	def unit_vector(from, to)
	    u = to.zip(from).map { |c2, c1| c2 - c1 }
	    n = Math.sqrt(u[0] * u[0] + u[1] * u[1])
	    if n > 0
		u.map { |c| c / n } # unit vector from -> to
	    end
	end

	BlackPen = Qt::Pen.new(Qt::Color.new('black'))

	# relation_node_info(from, to) -> arrow, from_pos, to_pos
	def relation_node_info(kind, from, to)
	    # Get element information (arrow, positions, id)
	    from_id, to_id = from.source_id, to.source_id
	    arrow = (canvas_arrows[ [kind, from_id, to_id] ] ||= Style.arrow(self))
	    arrow.pen = colors[kind] || BlackPen
	    from_pos, to_pos = yield(from_id), yield(to_id)
	    [arrow, from_pos, to_pos]
	end

	# Returns or updates the from -> to arrow
	def canvas_task_arrow(kind, from, to)
	    arrow, from_pos, to_pos = relation_node_info(kind, from, to, &method(:task_pos))
	    if !(u = unit_vector(from_pos, to_pos))
		arrow.start_point = from_pos
		arrow.end_point = to_pos
		return
	    end

	    from_pos, to_pos = [ [from, from_pos, :+], [to, to_pos, :-] ].
		map { |el, pos, op| [canvas_task(el).canvas_item[:rectangle], pos, op] }.
		map do |item, pos, op|
		x_scale = (u[0] / (item.width / 2)).abs
		y_scale = (u[1] / (item.height / 2)).abs
		if x_scale == 0
		    pos[0] = item.x + item.width / 2
		    pos[1] = (item.y + item.height / 2).send(op, (u[1] <=> 0) * item.height / 2)
		elsif y_scale == 0
		    pos[0] = (item.x + item.width / 2).send(op, (u[0] <=> 0) * item.width / 2)
		    pos[1] = item.y + item.height / 2
		else
		    scale = [x_scale, y_scale].max
		    pos[0] = pos[0].send(op, u[0] / scale)
		    pos[1] = pos[1].send(op, u[1] / scale)
		end

		pos
	    end

	    arrow.start_point = from_pos
	    arrow.end_point = to_pos
	    arrow.visible = !(hidden?(from) || hidden?(to))
	end

	def canvas_arrow(kind, from, to)
	    case from
	    when Marshallable::Task: canvas_task_arrow(kind, from, to)
	    else canvas_event_arrow(kind, from, to)
	    end
	end

	def state_change(task, symbol)
	    task_states[task] = symbol
	    task_item = canvas_task(task)
	    task_item.color = Style::TASK_COLORS[symbol]

	    task_visibility(task)
	    changed!
	end

	def each_event(task)
	    source_id = task.source_id if task
	    by_task[source_id].each { |id| yield(events[id]) }
	end
	def each_task(&iterator); tasks.each_value(&iterator) end
	def each_task_relation;  task_relations.each { |k, f, t| yield(k, tasks[f], tasks[t]) } end
	def each_event_relation; event_relations.each { |k, f, t| yield(k, events[f], events[t]) } end

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
	    else
		canvas_events[gen.source_id] ||= Style.event(gen, self)
	    end
	    by_task[task_id] << gen.source_id
	end

	def removed_relation(kind, from, to)
	    if arrow = canvas_arrows.delete( [kind, from.source_id, to.source_id] )
		arrow.dispose
	    end
	end
	private :removed_relation

	def added_event_relation(time, kind, from, to)
	    event(from)
	    event(to)
	    event_relations << [kind, from.source_id, to.source_id]
	    changed!
	end
	def removed_event_relation(time, kind, from, to)
	    event_relations.delete( [kind, from.source_id, to.source_id] )
	    removed_relation(kind, from, to)
	    changed!
	end

	def added_task_relation(time, kind, from, to)
	    task(from)
	    task(to)
	    task_relations << [kind, from.source_id, to.source_id]
	    changed!
	end
	def removed_task_relation(time, kind, from, to)
	    task_relations.delete( [kind, from.source_id, to.source_id] )
	    removed_relation(kind, from, to)
	    changed!
	end

	def task_initialize(time, task, start, stop)
	    task(task)
	    changed!
	end




	def new_transaction(time, trsc)
	    plans[trsc.plan.source_id] << trsc
	end
	def committed_transaction(time, trsc)
	    STDERR.puts "commited"
	    plans[trsc.plan.source_id].delete(trsc)
	    plans.delete(trsc.source_id)
	    changed!
	end
	def discarded_transaction(time, trsc)
	    plans[trsc.plan.source_id].delete(trsc)
	    plans.delete(trsc.source_id)
	    changed!
	end

	def discovered_tasks(time, plan, tasks)
	    plans[plan.source_id] += tasks
	    changed!
	end




	# Layouts the current graph using dot
	def layout
	    canvas_plans.each { |p| p.dispose }
	    canvas_plans.clear

	    layout = Time.elapse { DotLayout.layout(self, dot_scale) }
	    STDERR.puts "layout: #{Time.at(layout).to_hms}"
	end
	slots 'layout()'
	alias :update :layout

	# Checks if the canvas item for +object+ is hidden
	def hidden?(object)
	    if t = canvas_tasks[object.source_id]
		!t.visible?
	    elsif e = canvas_events[object.source_id]
		!e.visible?
	    end
	end

	# Updates the visibility of task +t+ according to its state
	# and the 'finished' and 'finalized' buttons
	def task_visibility(t)
	    next unless s = task_states[t]

	    if (s == :success || s == :failed)
		flag = @show_finished.on?
	    elsif (s == :finalized)
		flag = @show_finalized.on?
	    else return
	    end

	    canvas_tasks[t.source_id].visible = flag
	    each_task_relation do |kind, from, to|
		if from == t || to == t
		    arrow = canvas_arrows[ [from.source_id, to.source_id] ]
		    arrow.visible = flag if arrow
		end
	    end
	end

	# Updates the visibility of all tasks
	# See #task_visibility
	def update_task_show
	    task_states.each { |t, _| task_visibility(t)  }
	    changed!
	end
	slots 'update_task_show()'
    end
end

