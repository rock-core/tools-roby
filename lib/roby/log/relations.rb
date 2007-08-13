require 'Qt4'
require 'utilrb/module/attr_predicate'
require 'roby/distributed/protocol'
require 'roby/log/dot'
require 'roby/log/plan_rebuilder'
require 'roby/log/gui/relations_view'

module Roby
    class PlanObject::DRoby
	def display_parent; end
	def display_create(display); end
	def display_events; ValueSet.new end
	def display_name(display); remote_name end
	def display(display, graphics_item)
	end
    end

    module EventGeneratorDisplay
	def self.pending_style
	    @@default_pending_brush ||= Qt::Brush.new(Qt::Color.new(Log::PENDING_EVENT_COLOR))
	    @@default_pending_pen   ||= Qt::Pen.new(Qt::Color.new(Log::PENDING_EVENT_COLOR))
	    [@@default_pending_brush, @@default_pending_pen]
	end
	def self.fired_style
	    @@default_fired_brush ||= Qt::Brush.new(Qt::Color.new(Log::FIRED_EVENT_COLOR))
	    @@default_fired_pen   ||= Qt::Pen.new(Qt::Color.new(Log::FIRED_EVENT_COLOR))
	    [@@default_fired_brush, @@default_fired_pen]
	end
	def self.priorities
	    @@priorities ||= Hash.new
	end

	def display_create(display)
	    scene = display.scene
	    circle = scene.add_ellipse(-Log::EVENT_CIRCLE_RADIUS, -Log::EVENT_CIRCLE_RADIUS, Log::EVENT_CIRCLE_RADIUS * 2, Log::EVENT_CIRCLE_RADIUS * 2)
	    text   = scene.add_text(display_name(display))
	    circle.brush, circle.pen = EventGeneratorDisplay.pending_style
	    circle.singleton_class.class_eval { attr_accessor :text }
	    circle.z_value = Log::EVENT_LAYER

	    text.parent_item = circle
	    text_width   = text.bounding_rect.width
	    text.set_pos(-text_width / 2, 0)
	    circle.text = text
	    circle
	end
    end

    class EventGenerator::DRoby
	include EventGeneratorDisplay

	def display_name(display)
	    name = display.filter_prefixes(model.ancestors[0][0].dup)
	    if display.show_ownership
		name << "\n#{owners_to_s}"
	    end
	    name
	end
    end

    class TaskEventGenerator::DRoby
	include EventGeneratorDisplay
	def display_parent; task end
	def display_name(display); symbol.to_s end

	def display(display, graphics_item)
	end
    end

    module LoggedTask
	def layout_events(display)
	    graphics_item = display[self]

	    width, height = 0, 0
	    events = self.events.map do |_, e| 
		next unless display.displayed?(e)
		next unless circle = display[e]
		br = (circle.bounding_rect | circle.children_bounding_rect)
		[e, circle, br]
	    end
	    events.compact!
	    events = events.sort_by { |ev, _| EventGeneratorDisplay.priorities[ev] }

	    events.each do |_, circle, br|
		w, h = br.width, br.height
		height = h if h > height
		width += w
	    end
	    width  += Log::TASK_EVENT_SPACING * (events.size + 1)
	    height += Log::TASK_EVENT_SPACING

	    x = -width  / 2 + Log::TASK_EVENT_SPACING
	    events.each do |e, circle, br|
		w  = br.width
		circle.set_pos(x + w / 2, -br.height / 2 + Log::EVENT_CIRCLE_RADIUS + Log::TASK_EVENT_SPACING)
		x += w + Log::TASK_EVENT_SPACING
	    end

	    width = Log::DEFAULT_TASK_WIDTH unless width > Log::DEFAULT_TASK_WIDTH
	    height = Log::DEFAULT_TASK_HEIGHT unless height > Log::DEFAULT_TASK_HEIGHT

	    if @width != width || @height != height
		@width, @height = width, height
		coords = Qt::RectF.new -(width / 2), -(height / 2), width, height
		graphics_item.rect = coords
	    end

	    text = graphics_item.text
	    text.set_pos(- text.bounding_rect.width / 2, height / 2 + Log::TASK_EVENT_SPACING)
	end

	def display_create(display)
	    scene = display.scene
	    rect = scene.add_rect Qt::RectF.new(0, 0, 0, 0)
	    text = scene.add_text display_name(display)
	    rect.brush = Qt::Brush.new(Log::TASK_BRUSH_COLORS[:pending])
	    rect.pen   = Qt::Pen.new(Log::TASK_PEN_COLORS[:pending])
	    @displayed_state = :pending
	    text.parent_item = rect
	    rect.singleton_class.class_eval { attr_accessor :text }
	    rect.text = text
	    rect.z_value = Log::TASK_LAYER

	    rect.set_data(0, Qt::Variant.new(self.object_id))
	    rect
	end
    end

    class Task::DRoby
	include LoggedTask
	def display_name(display)
	    name = display.filter_prefixes(model.ancestors[0][0].dup)
	    if display.show_ownership
		name << "\n#{owners_to_s}"
	    end
	    name
	end

	def display(display, graphics_item)
	    new_state = if plan && plan.finalized_tasks.include?(self)
			    :finalized
			else
			    [:success, :finished, :started, :pending].
				find { |flag| flags[flag] } 
			end

	    new_state ||= :pending
	    if @displayed_state != new_state
		graphics_item.brush = Qt::Brush.new(Log::TASK_BRUSH_COLORS[new_state])
		graphics_item.pen   = Qt::Pen.new(Log::TASK_PEN_COLORS[new_state])
		@displayed_state = new_state
	    end

	    graphics_item.text.plain_text = display_name(display).to_s

	    super
	    layout_events(display)
	end
    end

    class Transaction::Proxy::DRoby
	include LoggedTask

	attr_writer :real_object
	def flags; real_object.flags end

	def display_parent; end
	def display_name(display); "tProxy of #{real_object.display_name(display)}" end
	def display_create(display)
	    scene = display.scene
	    item = super

	    brush = item.brush
	    brush.style = Qt::BDiagPattern
	    item.brush = brush
	    item
	end
	def display(display, graphics_item)
	    layout_events(display)
	end
    end

    module LoggedPlan
	PLAN_STROKE_WIDTH = 5
	# The plan depth, i.e. its distance from the root plan
	attr_reader :depth
	# The max depth of the plan tree in this branch
	attr_reader :max_depth

	def display_create(display)
	    scene = display.scene
	    pen            = Qt::Pen.new
	    pen.width      = PLAN_STROKE_WIDTH
	    pen.style      = Qt::SolidLine
	    pen.cap_style  = Qt::SquareCap
	    pen.join_style = Qt::RoundJoin
	    scene.add_rect Qt::RectF.new(0, 0, 0, 0), pen
	end
	def display_parent; parent_plan end
	def display(display, item)
	    #STDERR.puts "DISPLAYING PLAN\n  #{caller.join("\n  ")}"
	end
    end

    module Log
	EVENT_CIRCLE_RADIUS = 3
	TASK_EVENT_SPACING  = 5
	DEFAULT_TASK_WIDTH = 20
	DEFAULT_TASK_HEIGHT = 10
	ARROW_COLOR   = Qt::Color.new('black')
	ARROW_OPENING = 30
	ARROW_SIZE    = 10

	TASK_BRUSH_COLORS = {
	    :pending  => Qt::Color.new('#6DF3FF'),
	    :started  => Qt::Color.new('#B0FFA6'),
	    :success  => Qt::Color.new('#E2E2E2'),
	    :finished => Qt::Color.new('#E2A8A8'),
	    :finalized => Qt::Color.new('#555555')
	}
	TASK_PEN_COLORS = {
	    :pending  => Qt::Color.new('#6DF3FF'),
	    :started  => Qt::Color.new('#B0FFA6'),
	    :success  => Qt::Color.new('#E2E2E2'),
	    :finished => Qt::Color.new('#E2A8A8'),
	    :finalized => Qt::Color.new('#555555')
	}
	TASK_NAME_COLOR = 'black'
	TASK_FONTSIZE = 10

	PENDING_EVENT_COLOR    = 'black' # default color for events
	FIRED_EVENT_COLOR      = 'red'
	EVENT_FONTSIZE = 8

	PLAN_LAYER             = 0
	TASK_LAYER	       = PLAN_LAYER + 20
	EVENT_LAYER	       = PLAN_LAYER + 30

	FIND_MARGIN = 10

	class Qt::GraphicsScene
	    attr_reader :default_arrow_pen
	    attr_reader :default_arrow_brush
	    def add_arrow(size, pen = nil, brush = nil)
		@default_arrow_pen   ||= Qt::Pen.new(ARROW_COLOR)
		@default_arrow_brush ||= Qt::Brush.new(ARROW_COLOR)

		@arrow_points ||= (1..4).map { Qt::PointF.new(0, 0) }
		@arrow_points[1].x = -size
		@arrow_points[1].y = size / 2
		@arrow_points[2].x = -size
		@arrow_points[2].y = -size / 2
		polygon = Qt::PolygonF.new(@arrow_points)
		@arrow_line ||=   Qt::LineF.new(-1, 0, 0, 0)

		ending = add_polygon polygon, (pen || default_arrow_pen), (brush || default_arrow_brush)
		line   = add_line @arrow_line

		line.parent_item = ending
		ending.singleton_class.class_eval { attr_accessor :line }
		ending.line = line
		ending
	    end
	end

	def self.intersect_rect(w, h, from, to)
	    to_x, to_y = *to
	    from_x, from_y = *from

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

	    #from = intersect_rect(start_br.width, start_br.height, end_point, start_point)
	    from = [start_point.x, start_point.y]
	    to   = intersect_rect(end_br.width, end_br.height, from, [end_point.x, end_point.y])

	    dy = to[1] - from[1]
	    dx = to[0] - from[0]
	    alpha  = Math.atan2(dy, dx)
	    length = Math.sqrt(dx ** 2 + dy ** 2)

	    #arrow.line.set_line from[0], from[1], to[0], to[1]
	    arrow.resetMatrix
	    arrow.line.set_line(-length, 0, 0, 0)
	    arrow.translate to[0], to[1]
	    arrow.rotate(alpha * 180 / Math::PI)
	end

	class RelationsDisplay < Qt::Object
	    def splat?; true end

	    # The PlanRebuilder object for this display
	    attr_accessor :decoder

	    attr_reader :ui, :scene
	    attr_reader :main
	    attr_accessor :config_ui

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

	    # The array of events for which a command has been called, or which
	    # have been emitted. The order in this array is the arrival order
	    # of the corresponding events.
	    #
	    # An array element is [fired, event], when fired is true if the
	    # event has been fired, and false if it is pending
	    attr_reader :execution_events

	    # The set of postponed events that have occured since the last call
	    # to #update. Each element is [postponed_generator,
	    # until_generator]
	    attr_reader :postponed_events

	    # A pool of arrows items used to display the event signalling
	    attr_reader :signal_arrows

	    # A regex => boolean map of prefixes that should be removed from
	    # the task names
	    attr_reader :removed_prefixes

	    def filter_prefixes(string)
		# @prefixes_removal is computed in RelationsDisplay#update
		for prefix in @prefixes_removal
		    string = string.gsub(prefix, '')
		end
		string
	    end

	    # If true, show the ownership in the task descriptions
	    attr_accessor :show_ownership
	    # If true, show the arguments in the task descriptions
	    attr_accessor :show_arguments

	    attr_reader :signal_pen
	    attr_reader :forward_pen

	    def initialize
		@scene  = Qt::GraphicsScene.new
		super()

		@main   = Qt::MainWindow.new
		@ui     = Ui::RelationsView.new

		@signal_pen  = Qt::Pen.new
		@forward_pen = Qt::Pen.new
		forward_pen.dash_pattern = [5.0, 5.0]
		
		@graphics          = Hash.new
		@visible_objects   = ValueSet.new
		@flashing_objects  = Hash.new
		@arrows            = Hash.new
		@enabled_relations = Set.new
		@layout_relations  = Set.new
		@relation_colors   = Hash.new
		@relation_pens     = Hash.new(Qt::Pen.new(Qt::Color.new(ARROW_COLOR)))
		@relation_brushes  = Hash.new(Qt::Brush.new(Qt::Color.new(ARROW_COLOR)))
		@current_color     = 0

		@removed_prefixes = { 
		    "Roby::" => false, 
		    "Roby::Genom::" => false
		}
		@show_ownership = true
		@show_arguments = false

		@signalled_events  = []
		@execution_events  = []
		@postponed_events  = ValueSet.new
		@signal_arrows     = []

		ui.setupUi(self)
		ui.graphics.scene = scene

		@shortcuts = []
		shortcut = Qt::Shortcut.new(Qt::KeySequence.new('f'), main)
		connect(shortcut, SIGNAL('activated()'), self, SLOT('find()'))
		@shortcuts << shortcut
		main.resize 500, 500
	    end

	    def object_of(item)
		return if !(id = item.data(0)).valid?
		id = id.to_int

		obj, _ = graphics.find do |obj, obj_item| 
		    obj.object_id == id
		end
		obj
	    end

	    def stream=(data_stream)
		if decoder
		    clear
		end

		# Get a PlanRebuilder object tied to data_stream
		@decoder = data_stream.decoder(PlanRebuilder)
		decoder.displays << self
		ui.load_config

		# Initialize the display ...
		decoder.plans.each_key do |plan|
		    discovered_tasks(Time.now, plan, plan.known_tasks)
		    discovered_events(Time.now, plan, plan.free_events)
		end
		display
	    end

	    def [](item); graphics[item] end
	    def task_relation(from, to, rel, info)
		arrow(from, to, rel, info, TASK_LAYER)
	    end
	    def event_relation(form, to, rel, info)
		arrow(from, to, rel, info, EVENT_LAYER)
	    end

	    def arrow(from, to, rel, info, base_layer)
		id = [from, to, rel]
		unless item = arrows[id]
		    item = (arrows[id] ||= scene.add_arrow(ARROW_SIZE))
		    item.z_value      = base_layer - 1
		    item.pen   = item.line.pen = relation_pens[rel]
		    item.brush = relation_brushes[rel]
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
		objects = decoder.tasks.keys.
		    find_all { |object| displayed?(object) && regex === object.display_name(self) }
		objects.concat decoder.events.keys.
		    find_all { |object| displayed?(object) && regex === object.display_name(self) }

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
		scale = ui.graphics.matrix.m11
		if scale > 1
		    ui.graphics.resetMatrix
		    ui.graphics.scale 1, 1
		end
	    end
	    slots 'find()'

	    attr_accessor :keep_signals

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
		    end
		end
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
		    end
		end
	    end

	    attr_reader :relation_colors
	    attr_reader :relation_pens
	    attr_reader :relation_brushes
	    def relation_color(relation)
		if !relation_colors.has_key?(relation)
		    update_relation_color(relation, allocate_color)
		end
		relation_colors[relation]
	    end
	    def update_relation_color(relation, color)
		relation_colors[relation] = color
		color = Qt::Color.new(color)
		pen   = relation_pens[relation]    = Qt::Pen.new(color)
		brush = relation_brushes[relation] = Qt::Brush.new(color)
		arrows.each do |(_, _, rel), arrow|
		    if rel == relation
			arrow.pen = arrow.line.pen = pen
			arrow.brush = brush
		    end
		end
	    end

	    def layout_method=(new_method)
		return if new_method == @layout_method

		@layout_method  = nil
		@layout_options = nil
		if new_method
		    new_method =~ /^(\w+)(?: \[(.*)\])?$/
		    @layout_method    = $1
		    if $2
			@layout_options = $2.split(",").inject(Hash.new) do |h, v|
			    k, v = v.split("=")
			    h[k] = v
			    h
			end
		    end
		end
		display
	    end
	    def layout_options
		return @layout_options if @layout_options
		{ :rankdir => 'TB' }
	    end
	    def layout_method
		return @layout_method if @layout_method
		"dot"
	    end

	    def displayed?(object)
	       	visible_objects.include?(object) || 
		    flashing_objects.has_key?(object) 
	    end
	    def set_visibility(object, flag)
		return if visible_objects.include?(object) == flag

		if item = graphics[object]
		    item.visible = flag
		end

		if flag
		    visible_objects << object
		else
		    visible_objects.delete(object)
		end
	    end

	    def create_or_get_item(object)
		unless item = graphics[object]
		    item = graphics[object] = object.display_create(self)
		    if item
			item.parent_item = self[object.display_parent] if object.display_parent
			yield(item) if block_given?

			if !displayed?(object) 
			    item.visible = false
			end
		    end
		end

		item.visible = displayed?(object)
		item
	    end

	    # Add +object+ to the list of objects temporarily displayed. If a
	    # block is given, the object is removed when the block returns
	    # false. Otherwise, it is removed at the next display update
	    #
	    # If this method is called more than once for the same object, the
	    # object is removed when *all* blocks have returned false at least
	    # once
	    def add_flashing_object(object, &block)
		if block
		    flashing_objects[object] ||= []
		    flashing_objects[object] << block
		else
		    flashing_objects[object] ||= nil
		end

		create_or_get_item(object)
	    end
	    def clear_flashing_objects
		(flashing_objects.keys.to_value_set - visible_objects).each do |object|
		    if blocks = flashing_objects[object]
			blocks.delete_if { |block| !block.call }
			next unless blocks.empty?
		    end

		    if item = graphics[object]
			item.visible = false
		    end
		    flashing_objects.delete(object)
		end
	    end

	    def update
		return unless decoder

		# Compute the prefixes to remove from in filter_prefixes:
		# enable only the ones that are flagged, and sort them by
		# prefix length
		@prefixes_removal = removed_prefixes.find_all { |p, b| b }.
		    map { |p, b| p }.
		    sort_by { |p| p.length }.
		    reverse

		clear_flashing_objects

		# The sets of tasks and events know to the data stream
		all_tasks  = decoder.plans.inject(decoder.tasks.keys.to_value_set) do |all_tasks, (plan, _)|
		    all_tasks.merge plan.finalized_tasks
		end
		all_events = decoder.plans.inject(decoder.events.keys.to_value_set) do |all_events, (plan, _)|
		    all_events.merge plan.finalized_events
		end

		# Remove the items for objects that don't exist anymore
		(graphics.keys.to_value_set - all_tasks - all_events).each do |obj|
		    remove_graphics(graphics.delete(obj))
		    clear_arrows(obj)
		end

		visible_objects.merge(decoder.plans.keys.to_value_set)

		# Create graphics items for tasks and events if necessary, and
		# update their visibility according to the visible_objects set
		[all_tasks, all_events, decoder.plans.keys].each do |object_set|
		    object_set.each do |object|
			create_or_get_item(object) if displayed?(object)
		    end
		end

		EventGeneratorDisplay.priorities.clear
		execution_events.each_with_index do |(level, object), index|
		    EventGeneratorDisplay.priorities[object] = index
		    next if object.respond_to?(:task) && !displayed?(object.task)

		    graphics = if flashing_objects.has_key?(object)
				   graphics[object]
			       else
				   add_flashing_object(object)
			       end

		    graphics.brush, graphics.pen = 
			case level
			when 0
			    EventGeneratorDisplay.pending_style
			when 1
			    EventGeneratorDisplay.fired_style
			when 2
			    [EventGeneratorDisplay.fired_style[0], EventGeneratorDisplay.pending_style[1]]
			end
		end
		
		signalled_events.each do |_, from, to, _|
		    if from.respond_to?(:task) 
			next if !displayed?(from.task)
		    else
			next if !all_events.include?(from)
		    end
		    if to.respond_to?(:task) 
			next if !displayed?(to.task)
		    else
			next if !all_events.include?(to)
		    end

		    add_flashing_object from
		    add_flashing_object to
		end


		[all_tasks, all_events, decoder.plans.keys].each do |object_set|
		    object_set.each do |object|
			next unless displayed?(object)
			object.display(self, graphics[object])
		    end
		end

		# Update arrow visibility
		arrows.each do |(from, to, rel), item|
		    item.visible = (displayed?(from) && displayed?(to))
		end

		# Layout the graph
		layouts = decoder.plans.keys.find_all { |p| p.root_plan? }.
		    map do |p| 
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
			arrow.z_value      = EVENT_LAYER + 1
			arrow.line.z_value = EVENT_LAYER - 1
		    end

		    # It is possible that the objects have been removed in the
		    # same display cycle than they have been signalled. Do not
		    # display them if it is the case
		    unless displayed?(from) && displayed?(to)
			arrow.visible = false
			next
		    end
		    puts from if !self[from]
		    puts to   if !self[to]

		    arrow.visible = true
		    if forward
			arrow.line.pen = forward_pen
		    else
			arrow.line.pen = signal_pen
		    end
		    Log.arrow_set(arrow, self[from], self[to])
		end
		# ... and hide the remaining arrows that are not used anymore
		if signal_arrow_idx + 1 < signal_arrows.size
		    signal_arrows[(signal_arrow_idx + 1)..-1].each do |arrow| 
			arrow.visible = false 
		    end
		end

		unless keep_signals
		    signalled_events.clear
		    execution_events.delete_if { |fired, ev| fired }
		end
		postponed_events.clear
	    end

	    def remove_graphics(item, scene = nil)
		return unless item
		scene ||= item.scene
		scene.remove_item(item) if scene
	    end

	    def local_task(obj); decoder.local_task(obj) end
	    def local_event(obj); decoder.local_event(obj) end
	    def local_plan(obj); decoder.local_plan(obj) end
	    def local_object(obj); decoder.local_object(obj) end

	    def generator_called(time, generator, context)
		execution_events << [0, local_event(generator)]
	    end
	    def generator_fired(time, generator, event_id, event_time, event_context)
		generator = local_event(generator)

		found_pending = false
		execution_events.delete_if do |level, ev| 
		    if level == 0 && generator == ev
			found_pending = true
		    end
		end
		execution_events << [(found_pending ? 2 : 1), generator]
	    end
	    def generator_postponed(time, generator, context, until_generator, reason)
		postponed_events << [local_event(generator), local_event(until_generator)]
	    end
	    def generator_signalling(time, flag, from, to, event_id, event_time, event_context)
		signalled_events << [flag, local_event(from), local_event(to), event_id]
	    end
	    def generator_forwarding(time, flag, from, to, event_id, event_time, event_context)
		signalled_events << [flag, local_event(from), local_event(to), event_id]
	    end


	    def removed_task_child(time, parent, rel, child)
		remove_graphics(arrows.delete([local_task(parent), local_task(child), rel]))
	    end
	    def removed_event_child(time, parent, rel, child)
		remove_graphics(arrows.delete([local_event(parent), local_event(child), rel]))
	    end
	    def discovered_tasks(time, plan, tasks)
		tasks.each do |obj| 
		    obj.flags[:pending] = true if obj.respond_to?(:flags)
		    task = local_task(obj)

		    set_visibility(task, true)
		    task.events.each_value do |ev|
			if item = self[ev]
			    item.visible = false
			end
		    end
		end
	    end
	    def clear_arrows(object)
		arrows.delete_if do |(from, to, _), arrow|
		    if from == object || to == object
			remove_graphics(arrow)
			true
		    end
		end
	    end

	    def clear
		arrows.dup.each_value(&method(:remove_graphics))
		graphics.dup.each_value(&method(:remove_graphics))
		arrows.clear
		graphics.clear

		signal_arrows.each do |arrow|
		    arrow.visible = false
		end

		visible_objects.clear
		flashing_objects.clear
		signalled_events.clear
		execution_events.clear
		postponed_events.clear

		scene.update(scene.scene_rect)
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

