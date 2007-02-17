require 'Qt4'
require 'stringio'
require 'roby/adapters/genom'
require 'roby/log/dot'

module Roby
    module Log::Display
	def self.update_marshalled(object_set, marshalled)
	    if old = object_set[marshalled.remote_object]
		marshalled.copy_from(old)
		Kernel.swap!(old, marshalled)
		old.instance_variable_set("@__bgl_graphs__", marshalled.instance_variable_get("@__bgl_graphs__"))
		old
	    else
		object_set[marshalled.remote_object] = marshalled
	    end
	end

	EVENT_CIRCLE_RADIUS = 3
	TASK_EVENT_SPACING  = 5
	ARROW_COLOR   = 'black'
	ARROW_OPENING = 30
	ARROW_SIZE    = 15

	TASK_COLOR = {
	    nil        => '#6DF3FF',
	    :start     => '#B0FFA6',
	    :success   => '#E2E2E2',
	    :failed    => '#E2A8A8',
	    :finalized => '#000000'
	}
	TASK_NAME_COLOR = 'black'
	TASK_FONTSIZE = 10

	EVENT_COLOR    = 'black' # default color for events
	EVENT_FONTSIZE = 8

	class Distributed::MarshalledPlanObject
	    include DirectedRelationSupport
	    attr_accessor :graphics_item
	    def displayed?; graphics_item && graphics_item.visible? end
	    def copy_from(old)
		self.graphics_item = old.graphics_item
	    end

	    def display(scene)
		each_relation do |rel|
		    each_child_object(rel) do |child|
			data, arrow = self[child, rel]
			if !arrow
			    self[child, rel] = [data, scene.add_arrow(nil, nil, ARROW_SIZE, ARROW_OPENING)]
			end
		    end
		end
		graphics_item
	    end

	    # Removes this object from the display
	    def remove_display
		scene = graphics_item.scene
		return unless scene
		graphics_item.children.each do |child|
		    scene.remove_item(child)
		end
		scene.remove_item(graphics_item)
	    end
	end
	class Distributed::MarshalledEventGenerator
	    attr_reader :circle, :text

	    def copy_from(old)
		super
		@circle = old.circle
		@text   = old.text

		if displayed? && (remote_name != old.remote_name)
		    old_width = text.text_width
		    text.plain_text = remote_name
		    text.move_by((text.text_width - old_width) / 2, 0)
		end
	    end

	    def display_name; name end
	    def display(scene)
		unless graphics_item
		    circle_rect = Qt::RectF.new -EVENT_CIRCLE_RADIUS, -EVENT_CIRCLE_RADIUS, EVENT_CIRCLE_RADIUS * 2, EVENT_CIRCLE_RADIUS * 2
		    @circle = scene.add_ellipse(circle_rect)
		    @text   = scene.add_text(display_name)
		    circle.brush = Qt::Brush.new(Qt::Color.new(EVENT_COLOR))
		    text.parent_item = circle
		    text_width   = text.bounding_rect.width
		    text.pos = Qt::PointF.new(-text_width / 2, 0)
		    @graphics_item = circle
		end

		super
		graphics_item
	    end
	end

	class Distributed::MarshalledTaskEventGenerator
	    attr_writer :plan
	    attr_writer :task
	    def display_name; symbol.to_s end
	end
	class Distributed::MarshalledTask
	    def events
		@events ||= ValueSet.new
	    end

	    # The rectangle representing the task itself
	    attr_reader :rect
	    # The task name
	    attr_reader :text

	    def copy_from(old)
		super
		@events = old.events
		@rect   = old.rect
		@text   = old.text
	    end

	    def layout_events
		width, height = 0, 0
		height = 0
		events.each do |e|
		    e  = e.graphics_item
		    br = (e.bounding_rect | e.children_bounding_rect)
		    w, h = br.width, br.height
		    height = h if h > height
		    width += w
		end
		width  += TASK_EVENT_SPACING * (events.size + 1)
		height += TASK_EVENT_SPACING
		coords = Qt::RectF.new -(width / 2), -(height / 2), width, height
		rect.rect = coords

		x = -width  / 2 + TASK_EVENT_SPACING
		events.each do |e|
		    e  = e.graphics_item
		    br = (e.bounding_rect | e.children_bounding_rect)
		    w  = br.width
		    e.pos = Qt::PointF.new(x + w / 2, -br.height / 2 + EVENT_CIRCLE_RADIUS + TASK_EVENT_SPACING)
		    x += w + TASK_EVENT_SPACING
		end

		text.pos = Qt::PointF.new(- text.bounding_rect.width / 2, height / 2 + TASK_EVENT_SPACING)
	    end

	    def to_s
		"#{model.name}:0x#{Object.address_from_id(remote_object.__drbref).to_s(16)}"
	    end

	    def display_name
		name = "#{model.name}:0x#{Object.address_from_id(remote_object.__drbref).to_s(16)}"
		unless arguments.empty?
		    name += "\n " + arguments.map { |k, v| "#{k}: #{v}" }.join("\n ")
		end
		name
	    end
	    def display(scene)
		unless graphics_item
		    @rect = scene.add_rect Qt::RectF.new(0, 0, 0, 0)
		    @text = scene.add_text display_name
		    rect.brush = Qt::Brush.new(Qt::Color.new(TASK_COLOR[nil]))
		    rect.pen = Qt::Pen.new(Qt::Color.new(TASK_COLOR[nil]))
		    text.parent_item = rect
		    @graphics_item   = rect
		end

		# Display events, and compute the maximum event height
		events.each do |e| 
		    item = e.display(scene)
		    item.parent_item = graphics_item
		end

		super
		layout_events
		graphics_item
	    end
	    def remove_display
		events.each do |e| 
		    e.remove_display if e.graphics_item
		end
		super
	    end
	end
	class Distributed::MarshalledRemoteTransactionProxy
	    include DirectedRelationSupport
	    attr_reader :graphics_item
	    def display(scene)
	    end
	    def copy_from(old)
	    end
	    def displayed?; false end
	    def events; [] end
	end

	class Plan
	    attr_reader   :remote_object
	    attr_reader   :missions, :known_tasks, :free_events
	    attr_reader   :transactions
	    attr_accessor :root_plan
	    def initialize(remote_object)
		@root_plan    = true
		@remote_object = remote_object
		@missions     = ValueSet.new
		@known_tasks  = ValueSet.new
		@free_events  = ValueSet.new
		@transactions = ValueSet.new
	    end

	    def display(scene)
		known_tasks.each  { |t| t.display(scene) }
		free_events.each  { |e| e.display(scene) }
		transactions.each { |trsc| trsc.display(scene) }
	    end

	    def finalized_task(task)
		missions.delete(task)
		known_tasks.delete(task)
	    end
	    def finalized_event(event)
		free_events.delete(event)
	    end
	    def removed_transaction(trsc)
		transactions.delete(trsc)
	    end
	end

	class Qt::GraphicsScene
	    def add_arrow(start_object, end_object, size, opening)
		ellipse = add_ellipse Qt::RectF.new(- size / 2, - size / 2, size, size)
		line    = add_line    Qt::LineF.new(-1, 0, 0, 0)
		ellipse.start_angle = Integer((180 - opening) * 16)
		ellipse.span_angle  = Integer(2 * opening * 16)

		line.parent_item = ellipse
		ellipse.singleton_class.class_eval do
		    define_method(:line) { line }
		end
		if start_object && end_object
		    Display.arrow_set ellipse, start_object, end_object
		end
		ellipse
	    end
	end

	def self.correct_line(line, rect)
	    int = Qt::PointF.new
	    l = Qt::LineF.new(rect.top_left, rect.top_right)
	    if l.intersect(line, int) == Qt::LineF::BoundedIntersection
		return yield(int)
	    end
	    l = Qt::LineF.new(rect.top_right, rect.bottom_right)
	    if l.intersect(line, int) == Qt::LineF::BoundedIntersection
		return yield(int)
	    end
	    l = Qt::LineF.new(rect.bottom_right, rect.bottom_left)
	    if l.intersect(line, int) == Qt::LineF::BoundedIntersection
		return yield(int)
	    end
	    l = Qt::LineF.new(rect.bottom_left, rect.top_left)
	    if l.intersect(line, int) == Qt::LineF::BoundedIntersection
		return yield(int)
	    end
	end

	def self.arrow_set(arrow, start_object, end_object)
	    start_br = start_object.scene_bounding_rect
	    end_br   = end_object.scene_bounding_rect

	    start_point = start_br.center
	    end_point   = end_br.center

	    newline = Qt::LineF.new(start_point, end_point)
	    correct_line(newline, start_br) { |int| start_point = int }
	    correct_line(newline, end_br) { |int| end_point = int }

	    newline = Qt::LineF.new(start_point, end_point)
	    alpha = newline.angle( Qt::LineF.new(0, 0, 1, 0) )
	    alpha *= -1 if newline.dy < 0

	    arrow.resetMatrix
	    arrow.line.set_line(-newline.length, 0, 0, 0)
	    arrow.translate end_point.x, end_point.y
	    arrow.rotate alpha
	end

	class Relations < Qt::Object
	    def splat?; true end
	    attr_reader :plans

	    attr_reader :tasks
	    attr_reader :events

	    attr_reader :view, :scene
	    def initialize
		super()
		@scene = Qt::GraphicsScene.new
		@view  = Qt::GraphicsView.new(scene)
		@plans  = Hash.new
		@tasks  = Hash.new
		@events = Hash.new
	    end

	    def local_plan(plan)
		return unless plan
		@plans[plan.remote_object] ||= Plan.new(plan.remote_object)
	    end

	    def local_object(set, marshalled)
		marshalled = Log::Display.update_marshalled(set, marshalled)
		plan = if marshalled.respond_to?(:transaction)
			   local_plan(marshalled.transaction)
		       else
			   local_plan(marshalled.plan)
		       end
		if plan
		    yield(plan) if block_given?
		end
		marshalled
	    end

	    def local_task(task); local_object(tasks, task) end
	    def local_event(event)
		if event.respond_to?(:task)
		    task = local_task(event.task)
		    event.task = task
		    event.plan = task.plan
		    event = local_object(events, event)
		    task.events << event
		    event
		else
		    local_object(events, event) 
		end
	    end
	    def inserted_tasks(time, plan, task)
		local_plan(plan).missions << task.remote_object
	    end
	    def discarded_tasks(time, plan, task)
		local_plan(plan).missions.delete(task.remote_object)
	    end
	    def replaced_tasks(time, plan, from, to)
	    end
	    def discovered_events(time, plan, events)
		plan = local_plan(plan)
		events.each { |ev| plan.free_events << local_event(ev) }
	    end
	    def discovered_tasks(time, plan, tasks)
		plan = local_plan(plan)
		tasks.each { |t| plan.known_tasks << local_task(t) }
	    end
	    def garbage_task(time, plan, task)
	    end
	    def finalized_event(time, plan, event)
		event = local_event(event)
		local_plan(plan).finalized_event(event)
		if obj = events.delete(event.remote_object)
		    obj.remove_display if obj.graphics_item
		end
	    end
	    def finalized_task(time, plan, task)
		task = local_task(task)
		local_plan(plan).finalized_task(task)
		if obj = tasks.delete(task.remote_object)
		    obj.remove_display if obj.graphics_item
		end
	    end
	    def added_transaction(time, plan, trsc)
		plan = local_plan(plan)
		trsc = local_plan(trsc)
		plan.transactions << trsc
		trsc.root_plan = false
	    end
	    def removed_transaction(time, plan, trsc)
		plan = local_plan(plan)
		plans.delete(trsc)
		trsc = local_plan(trsc)

		plan.transactions.delete(trsc)
		# Removed tasks and proxies that have been moved from the
		# transaction to the plan before clearing the transaction
		plan.known_tasks.each do |obj|
		    trsc.known_tasks.delete(obj)
		end
		plan.free_events.each do |obj|
		    trsc.free_events.delete(obj)
		end
	    end

	    def added_task_child(time, parent, rel, child, info)
		parent = local_task(parent)
		child  = local_task(child)
		parent.add_child_object(child, rel, [info, nil])
	    end
	    def removed_task_child(time, parent, rel, child)
		parent = local_task(parent)
		child  = local_task(child)
		_, arrow = parent[child, rel]
		if arrow
		    arrow.scene.remove_item(arrow)
		end
		parent.remove_child_object(child, rel)
	    end
	    def added_event_child(time, parent, rel, child, info)
		parent = local_event(parent)
		child  = local_event(child)
		STDERR.puts [parent.object_id, child.object_id].to_s
		parent.add_child_object(child, rel, [info, nil])
	    end
	    def removed_event_child(time, parent, rel, child)
		parent = local_event(parent)
		child  = local_event(child)
		STDERR.puts [parent.object_id, child.object_id].to_s
		_, arrow = parent[child, rel]
		if arrow
		    arrow.scene.remove_item(arrow)
		end
		parent.remove_child_object(child, rel)
	    end

	    def [](remote_id)
		objects[remote_id]
	    end
	    def display
		plans.find_all { |_, p| p.root_plan }.
		    each do |_, p|
			p.display(scene)
			Layout.new.layout(p, 1)
		    end
	    end

	    def cycle_end(time, timings)
		time_to_s = timings[:start].to_hms
		if time_to_s == "325455:57:55.020"
		    raise EOFError
		end

		STDERR.puts time_to_s
		display
		Qt::Application.instance.process_events
	    end
	end
    end
end

