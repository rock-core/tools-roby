require 'Qt4'
require 'utilrb/module/attr_predicate'
require 'roby/distributed/protocol'
require 'roby/log/dot'
require 'roby/log/rebuild'
require 'roby/log/gui/relations_view'

module Roby
    module Log
	EVENT_CIRCLE_RADIUS = 3
	TASK_EVENT_SPACING  = 5
	DEFAULT_TASK_WIDTH = 20
	DEFAULT_TASK_HEIGHT = 10
	ARROW_COLOR   = Qt::Color.new('black')
	ARROW_OPENING = 30
	ARROW_SIZE    = 10

	TASK_COLORS = {
	    :pending  => Qt::Color.new('#6DF3FF'),
	    :started  => Qt::Color.new('#B0FFA6'),
	    :success  => Qt::Color.new('#E2E2E2'),
	    :failed   => Qt::Color.new('#E2A8A8')
	}
	TASK_NAME_COLOR = 'black'
	TASK_FONTSIZE = 10

	EVENT_COLOR    = 'black' # default color for events
	EVENT_FONTSIZE = 8

	PLAN_LAYER             = 0
	TASK_RELATIONS_LAYER   = 50
	EVENT_RELATIONS_LAYER  = 51
	EVENT_SIGNALLING_LAYER = 52

	FIND_MARGIN = 10

	class Distributed::MarshalledPlanObject
	    def display_parent; end
	    def display_create(scene); end
	    def display_events; [] end
	    def display_name; remote_name end
	    def display(display, graphics_item)
	    end
	end
	class Distributed::MarshalledEventGenerator
	    def display_create(scene)
		circle_rect = Qt::RectF.new -EVENT_CIRCLE_RADIUS, -EVENT_CIRCLE_RADIUS, EVENT_CIRCLE_RADIUS * 2, EVENT_CIRCLE_RADIUS * 2
		circle = scene.add_ellipse(circle_rect)
		text   = scene.add_text(display_name)
		circle.brush = Qt::Brush.new(Qt::Color.new(EVENT_COLOR))
		circle.singleton_class.class_eval { attr_accessor :text }
		circle.z_value = PLAN_LAYER + 2

		text.parent_item = circle
		text_width   = text.bounding_rect.width
		text.pos = Qt::PointF.new(-text_width / 2, 0)
		circle.text = text
		circle
	    end

	    def display_name
		unless @display_name
		    model_name = if model.respond_to?(:remote_name)
				     model.remote_name
				 else
				     model.name
				 end
		    model_name = model_name.gsub /Generator$/, ''
		    model_name = model_name.gsub /^Roby::/, ''
		    @display_name = "#{model_name}\n0x#{Object.address_from_id(remote_object.__drbref).to_s(16)}"
		end

		@display_name
	    end
	end

	class Distributed::MarshalledTaskEventGenerator
	    def display_parent; task end
	    def display_name; @display_name ||= symbol.to_s end
	end

	class Distributed::MarshalledTask
	    def layout_events(display)
		graphics_item = display[self]

		width, height = 0, 0
		events = self.events.map do |e| 
		    next unless display.enabled_event_relations? || display.displayed?(e.remote_object)
		    next unless e = display[e]
		    br = (e.bounding_rect | e.children_bounding_rect)
		    [e, br]
		end
		events.compact!

		events.each do |e, br|
		    w, h = br.width, br.height
		    height = h if h > height
		    width += w
		end
		width  += TASK_EVENT_SPACING * (events.size + 1)
		height += TASK_EVENT_SPACING

		x = -width  / 2 + TASK_EVENT_SPACING
		events.each do |e, br|
		    w  = br.width
		    e.pos = Qt::PointF.new(x + w / 2, -br.height / 2 + EVENT_CIRCLE_RADIUS + TASK_EVENT_SPACING)
		    x += w + TASK_EVENT_SPACING
		end

		width = DEFAULT_TASK_WIDTH unless width > DEFAULT_TASK_WIDTH
		height = DEFAULT_TASK_HEIGHT unless height > DEFAULT_TASK_HEIGHT

		if @width != width || @height != height
		    @width, @height = width, height
		    coords = Qt::RectF.new -(width / 2), -(height / 2), width, height
		    graphics_item.rect = coords
		    text = graphics_item.text
		    text.pos = Qt::PointF.new(- text.bounding_rect.width / 2, height / 2 + TASK_EVENT_SPACING)
		end
	    end

	    def to_s
		model_name = if model.respond_to?(:remote_name)
				 model.remote_name
			     else
				 model.name
			     end

		name = "#{model_name}:0x#{Object.address_from_id(remote_object.__drbref).to_s(16)}"
	    end

	    def display_name
		unless @display_name
		    model_name = model.ancestors.first.first
		    @display_name = "#{model_name}\n0x#{Object.address_from_id(remote_object.__drbref).to_s(16)}"
		end

		@display_name
	    end

	    def display_create(scene)
		rect = scene.add_rect Qt::RectF.new(0, 0, 0, 0)
		text = scene.add_text display_name
		rect.brush = Qt::Brush.new(TASK_COLORS[:pending])
		rect.pen = Qt::Pen.new(TASK_COLORS[:pending])
		text.parent_item = rect
		rect.singleton_class.class_eval { attr_accessor :text }
		rect.text = text
		rect.z_value = PLAN_LAYER + 1
		rect
	    end

	    def display(display, graphics_item)
		new_state = [:success, :finished, :started].
		    find { |flag| flags[flag] } 

		if @displayed_state != new_state
		    graphics_item.brush = Qt::Brush.new(TASK_COLORS[new_state])
		    @displayed_state = new_state
		end

		super
		layout_events(display)
	    end
	end
	class Distributed::MarshalledRemoteTransactionProxy
	    include DirectedRelationSupport

	    def events; [] end

	    def display_parent; end
	    def display_name; "tProxy(#{real_object.display_name})" end
	    def display_create(scene); end
	    def display(display, graphics_item); end
	end

	class Qt::GraphicsScene
	    def add_arrow(size)
		polygon = Qt::PolygonF.new [
			       Qt::PointF.new(0, 0),
			       Qt::PointF.new(-size, size / 2),
			       Qt::PointF.new(-size, -size / 2),
			       Qt::PointF.new(0, 0)]

		ending = add_polygon polygon, Qt::Pen.new(ARROW_COLOR), Qt::Brush.new(ARROW_COLOR)
		line   = add_line    Qt::LineF.new(-1, 0, 0, 0)

		line.parent_item = ending
		ending.singleton_class.class_eval { attr_accessor :line }
		ending.line = line
		ending
	    end
	end

	def self.intersect_rect(w, h, from, to)
	    to_x, to_y = to.x, to.y
	    from_x, from_y = from.x, from.y

	    # We only use half dimensions since 'to' is supposed to be be the
	    # center of the rectangle we are intersecting
	    w /= 2
	    h /= 2

	    dx    = (to_x - from_x)
	    dy    = (to_y - from_y)
	    delta_x = dx / dy * h
	    if dy != 0 && delta_x.abs < w
		if dy > 0
		    [to_x - delta_x, to_y - h]
		else
		    [to_x + delta_x, to_y + h]
		end
	    elsif dx != 0
		delta_y = dy / dx * w
		if dx > 0
		    [to_x - w, to_y - delta_y]
		else
		    [to_x + w, to_y + delta_y]
		end
	    else
		[0, 0]
	    end
	end
	
	def self.correct_line(from, to, rect)
	    intersect_rect(rect.width, rect.height, from, to)
	end

	def self.arrow_set(arrow, start_object, end_object)
	    start_br    = start_object.scene_bounding_rect
	    end_br      = end_object.scene_bounding_rect
	    start_point = start_br.center
	    end_point   = end_br.center

	    from = intersect_rect(start_br.width, start_br.height, end_point, start_point)
	    to   = intersect_rect(end_br.width, end_br.height, start_point, end_point)

	    dy = to[1] - from[1]
	    dx = to[0] - from[0]
	    alpha  = Math.atan2(dy, dx)
	    length = Math.sqrt(dx ** 2 + dy ** 2)

	    #arrow.line.set_line from[0], from[1], to[0], to[1]
	    arrow.resetMatrix
	    arrow.line.set_line(-length, 0, 0, 0)
	    arrow.translate to[0], to[1]
	    arrow.rotate(alpha * 180 / Math::PI)
	
	    br = arrow.line.scene_bounding_rect
	end

	class RelationsDisplay < Qt::Object
	    def splat?; true end
	    # The data source for this relation display
	    attr_accessor :data_source

	    attr_reader :ui, :scene
	    attr_reader :main

	    # A [DRbObject, DRbObject] => GraphicsItem mapping of arrows
	    attr_reader :arrows

	    # A DRbObject => GraphicsItem mapping
	    attr_reader :graphics

	    # The set of objects that are to be shown permanently
	    attr_reader :visible_objects

	    # A set of events that are shown during only two calls of #update
	    attr_reader :flashing_objects

	    # The set of signals since the last call to #update
	    # Each element is [flag, from, to, event_id]
	    attr_reader :signalled_events

	    # The set of event generators which have been called but not yet
	    # fired. This is actually the list of their remote_object
	    attr_reader :pending_events

	    # The set of postponed events that have occured since the last call
	    # to #update. Each element is [postponed_generator,
	    # until_generator]
	    attr_reader :postponed_events

	    # A pool of arrows items used to display the event signalling
	    attr_reader :signal_arrows

	    def initialize
		@scene  = Qt::GraphicsScene.new
		super()

		@main   = Qt::Widget.new
		@ui     = Ui::RelationsView.new
		ui.setupUi(main)
		ui.graphics.scene = scene
		
		@graphics          = Hash.new
		@visible_objects   = Set.new
		@flashing_objects  = Hash.new
		@arrows            = Hash.new
		@enabled_relations = Set.new
		@layout_relations  = Set.new
		@relation_colors   = Hash.new
		@current_color     = 0

		@signalled_events  = []
		@pending_events    = Set.new
		@postponed_events  = []
		@signal_arrows     = []

		@shortcuts = []
		shortcut = Qt::Shortcut.new(Qt::KeySequence.new('f'), main)
		connect(shortcut, SIGNAL('activated()'), self, SLOT('find()'))
		@shortcuts << shortcut
		main.resize 500, 500
	    end

	    def [](item); graphics[item.remote_object] end
	    def arrow(from, to, rel, info)
		id = [from.remote_object, to.remote_object, rel]
		unless item = arrows[id]
		    item = (arrows[id] ||= scene.add_arrow(ARROW_SIZE))
		    item.z_value = EVENT_RELATIONS_LAYER
		    color = Qt::Color.new(relation_color(rel))
		    item.pen = item.line.pen = Qt::Pen.new(color)
		    item.brush = Qt::Brush.new(color)
		end
		Log.arrow_set item, self[from], self[to]
	    end

	    # Centers the view on the set of object found which matches
	    # +regex+.  If +regex+ is nil, ask one to the user
	    def find(regex = nil)
		unless regex
		    regex = Qt::InputDialog.get_text main, 'Find objects in relation view', 'Object name'
		    return unless regex && !regex.empty?
		end
		regex = /#{regex.to_str}/i if regex.respond_to?(:to_str)

		# Get the tasks and events matching the string
		objects = data_source.tasks.
		    find_all { |_, object| displayed?(object.remote_object) && regex === object.display_name }
		objects.concat data_source.events.
		    find_all { |_, object| displayed?(object.remote_object) && regex === object.display_name }
		objects.map! { |_, object| object }

		return if objects.empty?

		# Find the graphics items
		bb = objects.inject(Qt::RectF.new) do |bb, object| 
		    if item = self[object]
			item.selected = true
			bb | item.scene_bounding_rect | item.map_to_scene(item.children_bounding_rect).bounding_rect
		    else
			bb
		    end
		end
		bb.adjust -FIND_MARGIN, -FIND_MARGIN, FIND_MARGIN, FIND_MARGIN
		ui.graphics.fit_in_view bb, Qt::KeepAspectRatio
	    end
	    slots 'find()'

	    COLORS = %w{'black' #800000 #008000 #000080 #C05800 #6633FF #CDBE70 #CD8162 #A2B5CD}
	    attr_reader :current_color
	    # returns the next color in COLORS, cycles if at the end of the array
	    def allocate_color
		@current_color = (current_color + 1) % COLORS.size
		COLORS[current_color]
	    end

	    def relation_enabled?(relation); @enabled_relations.include?(relation) end
	    def layout_relation?(relation); relation_enabled?(relation) || @layout_relations.include?(relation) end

	    def enable_relation(relation)
		return if relation_enabled?(relation)
		@enabled_relations << relation
		arrows.each do |(_, _, rel), arrow|
		    if rel == relation
			arrow.visible = true 
			arrow.line.visible = true
		    end
		end

		@enabled_task_relations  ||= !!(relation.name =~ /TaskStructure/)
		@enabled_event_relations ||= !!(relation.name =~ /EventStructure/)
	    end

	    attr_reader :enabled_relations
	    def layout_relation(relation)
		disable_relation(relation)
		@layout_relations << relation
	    end
	    def ignore_relation(relation)
		disable_relation(relation)
		@layout_relations.delete(relation)
	    end

	    def disable_relation(relation)
		return unless relation_enabled?(relation)
		@enabled_relations.delete(relation)
		arrows.each do |(_, _, rel), arrow|
		    if rel == relation
			arrow.visible = false 
			arrow.line.visible = false
		    end
		end

		self.enabled_task_relations  = enabled_relations.find { |rel| rel.name =~ /TaskStructure/ }
		self.enabled_event_relations = enabled_relations.find { |rel| rel.name =~ /EventStructure/ }
	    end

	    attr_reader :relation_colors
	    def relation_color(relation)
		relation_colors[relation] ||= allocate_color
	    end
	    def update_relation_color(relation, color)
		relation_colors[relation] = color
		color = Qt::Color.new(color)
		pen   = Qt::Pen.new(color)
		brush = Qt::Brush.new(color)
		arrows.each do |(_, _, rel), arrow|
		    if rel == relation
			arrow.pen = arrow.line.pen = pen
			arrow.brush = brush
		    end
		end
	    end

	    def layout_method=(new_method)
		if new_method
		    new_method =~ /^(\w+)(?: \[(\w+)\])?$/
		    @layout_method    = $1
		    @layout_direction = $2
		else
		    @layout_method    = nil
		    @layout_direction = nil
		end
	    end
	    def layout_direction
		return @layout_direction if @layout_direction
		if enabled_event_relations? && !enabled_task_relations?
		    "LR"
		else "TB"
		end
	    end
	    def layout_method
		return @layout_method if @layout_method
		if enabled_event_relations? && enabled_task_relations?
		    "circo"
		else "dot"
		end
	    end

	    def displayed?(remote_object)
	       	visible_objects.include?(remote_object) || 
		    flashing_objects.has_key?(remote_object) 
	    end
	    def set_visibility(remote_object, flag)
		return if visible_objects.include?(remote_object) == flag

		if item = graphics[remote_object]
		    item.visible = flag
		    item.children.each do |child|
			child.visible = false
		    end
		end
		if flag
		    visible_objects << remote_object
		else
		    visible_objects.delete(remote_object)
		end
	    end

	    attr_predicate :enabled_task_relations?, true
	    attr_predicate :enabled_event_relations?, true

	    def generator_called(time, generator, context)
		pending_events << local_event(generator)
	    end
	    def generator_fired(time, generator, event_id, event_time, event_context)
		pending_events.delete(local_event(generator))
	    end
	    def generator_postponed(time, generator, context, until_generator, reason)
		postponed_events << [data_source.local_event(generator), data_source.local_event(until_generator)]
	    end
	    def generator_signalling(time, flag, from, to, event_id, event_time, event_context)
		signalled_events << [flag, data_source.local_event(from), data_source.local_event(to), event_id]
	    end
	    def generator_forwarding(time, flag, from, to, event_id, event_time, event_context)
		signalled_events << [flag, data_source.local_event(from), data_source.local_event(to), event_id]
	    end

	    def create_or_get_item(object)
		remote_object = object.remote_object
		unless item = graphics[remote_object]
		    item = graphics[remote_object] = object.display_create(scene)
		    if item
			item.flags = item.flags + Qt::ItemIsSelectable
			yield(item) if block_given?

			if !displayed?(remote_object) 
			    item.visible = false
			end
		    end
		end
		item
	    end

	    def add_flashing_object(remote_object, &block)
		if block
		    flashing_objects[remote_object] ||= []
		    flashing_objects[remote_object] << block
		else
		    flashing_objects[remote_object] = nil
		end

		if item = graphics[remote_object]
		    item.visible = true
		end
	    end
	    def clear_flashing_objects
		(flashing_objects.keys.to_set - visible_objects).each do |remote_object|
		    if blocks = flashing_objects[remote_object]
			blocks.delete_if { |block| !block.call }
			next unless blocks.empty?
		    end

		    # Beware: the item may have been removed if the object has been
		    # finalized between the two calls to #update
		    if item = graphics[remote_object]
			item.visible = false
		    end
		    flashing_objects.delete(remote_object)
		end
	    end

	    def update
		return unless data_source
		clear_flashing_objects

		signalled_events.each do |_, from, to, _|
		    add_flashing_object from.remote_object
		    add_flashing_object to.remote_object
		end

		pending_events.each do |remote_object|
		    next if flashing_objects.has_key?(remote_object)
		    add_flashing_object(remote_object) { pending_events.include?(remote_object) }
		end

		# Create graphics items for tasks and events if necessary, and
		# update their visibility according to the visible_objects set
		data_source.tasks.each_value { |task| create_or_get_item(task) }
		data_source.events.each_value do |event| 
		    create_or_get_item(event) do |item|
			item.parent_item = self[event.display_parent] if event.display_parent
		    end
		end

		# Update the displayed objects
		data_source.tasks.each_value do |task|
		    next unless displayed?(task.remote_object)
		    task.display(self, graphics[task.remote_object])
		end
		data_source.events.each_value do |event| 
		    next unless displayed?(event.remote_object)
		    event.display(self, graphics[event.remote_object])
		end

		# Layout the graph
		layouts = data_source.plans.find_all { |_, p| p.root_plan }.
		    map do |_, p| 
			dot = Layout.new
			dot.layout(self, p)
			dot
		    end
		layouts.each { |dot| dot.apply }
		
		# Display the signals
		signal_arrow_idx = -1
		signalled_events.each_with_index do |(forward, from, to, event_id), signal_arrow_idx|
		    unless arrow = signal_arrows[signal_arrow_idx]
			arrow = signal_arrows[signal_arrow_idx] = scene.add_arrow(ARROW_SIZE)
			arrow.z_value = EVENT_SIGNALLING_LAYER
		    end

		    # It is possible that the objects have been removed in the same display cycle than
		    # they have been signalled. Do not display them if it is the case
		    unless self[from] && self[to]
			arrow.visible = false
			arrow.line.visible = false
			next
		    end

		    arrow.visible = true
		    arrow.line.visible = true
		    Log.arrow_set(arrow, self[from], self[to])
		end
		# ... and hide the remaining arrows that are not used anymore
		if signal_arrow_idx + 1 < signal_arrows.size
		    signal_arrows[(signal_arrow_idx + 1)..-1].each do |arrow| 
			arrow.visible = false 
			arrow.line.visible = false
		    end
		end

		signalled_events.clear
		postponed_events.clear
	    end

	    def remove_graphics(item, scene = nil)
		return unless item
		scene ||= item.scene
		item.children.each do |child|
		    remove_graphics(child, scene)
		end
		scene.remove_item(item) if scene
	    end

	    def local_event(obj); data_source.local_event(obj) end
	    def remote_object(obj); data_source.remote_object(obj) end

	    def removed_task_child(time, parent, rel, child)
		remove_graphics(arrows.delete([remote_object(parent), remote_object(child), rel]))
	    end
	    def removed_event_child(time, parent, rel, child)
		remove_graphics(arrows.delete([remote_object(parent), remote_object(child), rel]))
	    end
	    def discovered_events(time, plan, events)
		return unless enabled_event_relations?
		events.each { |obj| set_visibility(remote_object(obj), true) }
	    end
	    def discovered_tasks(time, plan, tasks)
		tasks.each  { |obj| set_visibility(remote_object(obj), true) }
	    end
	    def clear_arrows(object)
		arrows.delete_if do |(from, to, _), arrow|
		    if from == object || to == object
			remove_graphics(arrow)
			true
		    end
		end
	    end
	    def finalized_event(time, plan, event)
		remove_graphics(graphics.delete(event))
		clear_arrows(event)
	    end
	    def finalized_task(time, plan, task)
		remove_graphics(graphics.delete(task))
		clear_arrows(task)
	    end

	    def clear
		arrows.each_value(&method(:remove_graphics))
		graphics.each_value(&method(:remove_graphics))
		arrows.clear
		graphics.clear

		signal_arrows.each do |arrow|
		    arrow.visible = false
		    arrow.line.visible = false
		end

		flashing_objects.clear
		signalled_events.clear
		pending_events.clear
		postponed_events.clear
	    end
	end
    end
end


if $0 == __FILE__
    require 'roby/log/file'
    include Roby::Log
    app     = Qt::Application.new(ARGV)
    builder = PlanRebuild.new
    rel     = RelationsDisplay.new(builder)
    rel.main_widget.show
    Roby::Log.replay(ARGV[0]) do |method_name, method_args|
	builder.send(method_name, *method_args) if builder.respond_to?(method_name)
	rel.send(method_name, *method_args) if rel.respond_to?(method_name)
    end
    app.exec
end

