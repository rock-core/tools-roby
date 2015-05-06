require 'roby/log/gui/qt4_toMSecsSinceEpoch'
require 'roby/log/gui/task_display_configuration'

require 'utilrb/module/attr_predicate'
require 'roby/distributed/protocol'

require 'roby/log/dot'
require 'roby/log/gui/styles'

module Roby
    module LogReplay
    module RelationsDisplay
        def self.all_task_relations
            if @all_task_relations
                @all_task_relations
            else
                result = []
                ObjectSpace.each_object(Roby::RelationSpace) do |space|
                    result.concat(space.relations) if space.applied.find { |t| t <= Roby::Task }
                end
                @all_task_relations = result
            end
        end

        module DisplayPlanObject
            def display_parent; end
            def display_create(display); end
            def display_events; ValueSet.new end
            def display_name(display); remote_name end
            def display(display, graphics_item)
            end
        end

        module DisplayEventGenerator
            include DisplayPlanObject
            def self.style(object, flags)
                # This is for backward compatibility only. All events are now marshalled
                # with their controllability.
                flags |= (object.controlable? ? EVENT_CONTROLABLE : EVENT_CONTINGENT)

                if (flags & EVENT_CALLED) == EVENT_CALLED
                    if (flags & EVENT_CONTROLABLE) != EVENT_CONTROLABLE
                        STDERR.puts "WARN: inconsistency in replayed logs. Found event call on #{object} #{object.object_id} which is marked as contingent (#{object.controlable?}"
                    end
                    flags |= EVENT_CONTROLABLE
                end

                if !styles.has_key?(flags)
                    raise ArgumentError, "event #{object} has flags #{flags}, which has no defined style (controlable=#{object.controlable?})"
                end

                styles[flags]
            end

            def self.styles
                return EVENT_STYLES
            end

            def self.priorities
                @@priorities ||= Hash.new
            end

            def display_create(display)
                scene = display.scene
                circle = scene.add_ellipse(-EVENT_CIRCLE_RADIUS, -EVENT_CIRCLE_RADIUS, EVENT_CIRCLE_RADIUS * 2, EVENT_CIRCLE_RADIUS * 2)
                text   = scene.add_text(display_name(display))
                circle.singleton_class.class_eval { attr_accessor :text }
                circle.z_value = EVENT_LAYER

                text.parent_item = circle
                text_width   = text.bounding_rect.width
                text.set_pos(-text_width / 2, 0)
                circle.text = text
                circle
            end

            def display_time_start(circle, pos); circle.translate(pos) end
            def display_time_end(circle, pos); end

            def display_name(display)
                name = if model.ancestors[0].name != 'Roby::EventGenerator'
                           [display.filter_prefixes(model.ancestors[0].name.dup)]
                       else
                           []
                       end

                if display.show_ownership
                    owners = self.owners.dup
                    owners.delete_if { |o| o.remote_name == "log_replay" }
                    if !owners.empty?
                        name << "[#{owners.map(&:name).join(", ")}]"
                    end
                end
                name.join("\n")
            end

            def display(display, graphics_item)
                graphics_item.text.plain_text = display_name(display).to_s
            end
        end

        module DisplayTaskEventGenerator
            include DisplayEventGenerator
            def display_parent; task end
            def display_name(display); symbol.to_s end
            def display(display, graphics_item)
            end
        end

        module DisplayTask
            # NOTE: we must NOT include ReplayTask here, as ReplayTask overloads
            # some methods from Task and it would break this overloading
            include DisplayPlanObject
            def layout_events(display)
                graphics_item = display[self]

                width, height = 0, 0
                events = self.each_event.map do |e| 
                    next unless display.displayed?(e)
                    next unless circle = display[e]
                    br = (circle.bounding_rect | circle.children_bounding_rect)
                    [e, circle, br]
                end
                events.compact!
                events = events.sort_by { |ev, _| DisplayEventGenerator.priorities[ev] }

                events.each do |_, circle, br|
                    w, h = br.width, br.height
                    height = h if h > height
                    width += w
                end
                width  += TASK_EVENT_SPACING * (events.size + 1)
                height += TASK_EVENT_SPACING

                x = -width  / 2 + TASK_EVENT_SPACING
                events.each do |e, circle, br|
                    w  = br.width
                    circle.set_pos(x + w / 2, -br.height / 2 + EVENT_CIRCLE_RADIUS + TASK_EVENT_SPACING)
                    x += w + TASK_EVENT_SPACING
                end

                width = DEFAULT_TASK_WIDTH unless width > DEFAULT_TASK_WIDTH
                height = DEFAULT_TASK_HEIGHT unless height > DEFAULT_TASK_HEIGHT

                if @width != width || @height != height
                    @width, @height = width, height
                    coords = Qt::RectF.new( -(width / 2), -(height / 2), width, height )
                    graphics_item.rect = coords
                end

                text = graphics_item.text
                text.set_pos(- text.bounding_rect.width / 2, height / 2 + TASK_EVENT_SPACING)
            end

            def display_create(display)
                scene = display.scene
                rect = scene.add_rect Qt::RectF.new(0, 0, 0, 0)
                text = scene.add_text display_name(display)
                rect.brush = Qt::Brush.new(TASK_BRUSH_COLORS[:pending])
                rect.pen   = Qt::Pen.new(TASK_PEN_COLORS[:pending])
                @displayed_state = :pending
                text.parent_item = rect
                rect.singleton_class.class_eval { attr_accessor :text }
                rect.text = text
                rect.z_value = TASK_LAYER

                @width, @height = nil

                rect.set_data(0, Qt::Variant.new(self.object_id.to_s))
                rect
            end

            def display_time_start(rect, pos); rect.left = pos end
            def display_time_end(rect, pos);   rect.right = pos end

            attr_accessor :last_event

            def display_name(display)
                name = display.filter_prefixes(model.ancestors[0].name.dup)
                if display.show_ownership
                    owners = self.owners.dup
                    owners.delete_if { |o| o.remote_name == "log_replay" }
                    if !owners.empty?
                        name << "\n[#{owners.map(&:name).join(", ")}]"
                    end
                end
                name
            end

            attr_reader :displayed_state
            def update_graphics(display, graphics_item)
                new_state = current_display_state(display.current_time)
                finalized = (finalization_time && finalization_time <= display.current_time)
                if displayed_state != [new_state, finalized]
                    if finalized
                        pen = Qt::Pen.new(TASK_PEN_COLORS[:finalized])
                        pen.width = 4
                        graphics_item.pen   = pen
                    else
                        graphics_item.pen   = Qt::Pen.new(TASK_PEN_COLORS[new_state])
                    end
                    graphics_item.brush = Qt::Brush.new(TASK_BRUSH_COLORS[new_state])
                    @displayed_state = [new_state, finalized]
                end

                graphics_item.text.plain_text = display_name(display).to_s
            end

            def display(display, graphics_item)
                update_graphics(display, graphics_item)
                super
            end

            # Generates a SVG representation of a given task model, using the
            # task as proxy for the model
            #
            # @param [Roby::Task] task the Roby task
            # @option options [String] :path a file path to which the SVG should
            #   be saved
            # @option options [Float] :scale_x (Layout::DOT_TO_QT_SCALE_FACTOR_X)
            # @option options [Float] :scale_y (Layout::DOT_TO_QT_SCALE_FACTOR_Y)
            #
            # @return [String,nil] if the file path is not set, the SVG content.
            #   Otherwise, nil.
            def self.to_svg(task, options = Hash.new)
                options = Kernel.validate_options options,
                    :path => nil,
                    :scale_x => Layout::DOT_TO_QT_SCALE_FACTOR_X,
                    :scale_y => Layout::DOT_TO_QT_SCALE_FACTOR_Y

                if !task.plan
                    plan = Roby::Plan.new
                    plan.extend DisplayPlan
                    plan.extend ReplayPlan
                    plan.add(task)
                end
                task.extend DisplayTask
                task.extend ReplayTask
                plan = task.plan

                display = RelationsCanvas.new([plan])
                display.display_plan_bounding_boxes = false
                display.layout_options.merge!(options.slice(:scale_x, :scale_y))
                task.each_event do |ev|
                    if ev.controlable?
                        plan.emitted_events << [EVENT_CALLED_AND_EMITTED, ev]
                    else
                        plan.emitted_events << [EVENT_EMITTED, ev]
                    end
                end
                task.model.all_forwardings.each do |source_name, targets|
                    source = task.event(source_name)
                    targets.each do |target_name|
                        plan.propagated_events << [PROPAG_FORWARD, [source], task.event(target_name)]
                    end
                end
                task.model.all_signals.each do |source_name, targets|
                    source = task.event(source_name)
                    targets.each do |target_name|
                        plan.propagated_events << [PROPAG_SIGNAL, [source], task.event(target_name)]
                    end
                end
                display.update
                scene = display.scene

		svg = Qt::SvgGenerator.new
                if path = options[:path]
                    svg.file_name = path
                else
                    buffer = svg.output_device = Qt::Buffer.new
                end
		svg.size = Qt::Size.new(Integer(scene.width), Integer(scene.height))
		painter = Qt::Painter.new
		painter.begin(svg)
		scene.render(painter)
		painter.end
                if !path
                    buffer.data
                end
            end
        end

        module DisplayTaskProxy
            include DisplayTask

            attr_writer :real_object
            def flags; real_object.flags end

            def display_parent; end
            def display_name(display); real_object.display_name(display) end
            def display_create(display)
                scene = display.scene
                item = super

                brush = item.brush
                brush.style = Qt::BDiagPattern
                item.brush = brush
                item
            end
            def display(display, graphics_item)
                graphics_item.text.plain_text = display_name(display).to_s
                layout_events(display)
            end
        end

        module DisplayPlan
            # NOTE: we must NOT include ReplayPlan here, as ReplayTask overloads
            # some methods from Task and it would break this overloading

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
            def display_parent
                if respond_to?(:plan) then plan
                end
            end
            def display(display, item)
            end
            def display_name(display)
                ""
            end
        end

        Roby::PlanObject.include DisplayPlanObject
        Roby::EventGenerator.include DisplayEventGenerator
        Roby::TaskEventGenerator.include DisplayTaskEventGenerator
        Roby::Task.include DisplayTask
        Roby::Task::Proxying.include DisplayTaskProxy
        Roby::Plan.include DisplayPlan

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

                @arrow_id ||= 0
                id = (@arrow_id += 1)
                line.setData(0, Qt::Variant.new(id.to_s))
                ending.setData(0, Qt::Variant.new(id.to_s))

		line.parent_item = ending
		ending.singleton_class.class_eval do
                    attr_accessor :line

                    def pen=(pen)
                        super
                        line.pen = pen
                    end
                end
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
            arrow
	end

	class RelationsCanvas < Qt::Object
            # Common configuration options for displays that represent tasks
	    include LogReplay::TaskDisplayConfiguration

            # The Qt::GraphicsScene we are manipulating
            attr_reader :scene

            # The set of plans that should be displayed
            attr_reader :plans

	    # A [object, object, relation] => GraphicsItem mapping of arrows
	    attr_reader :arrows

	    # A [object, object, relation] => GraphicsItem mapping of arrows
	    attr_reader :last_arrows

            attr_reader :free_arrows

	    # A DRbObject => GraphicsItem mapping
	    attr_reader :graphics

	    # The set of objects that are to be shown at the last update
	    attr_reader :visible_objects

	    # The set of objects that are selected for display in the :explicit
            # display mode
	    attr_reader :selected_objects

	    # A set of events that are shown during only two calls of #update
	    attr_reader :flashing_objects

	    # A pool of arrows items used to display the event signalling
	    attr_reader :signal_arrows

	    # True if the finalized tasks should not be displayed
	    attr_accessor :hide_finalized

            # @return [Boolean] true if the plan's bounding boxes should be
            #   displayed or not (true)
            attr_predicate :display_plan_bounding_boxes?, true

            # @return [Hash] set of options that should be passed to
            #   Graphviz#layout
            attr_reader :layout_options

	    def initialize(plans)
		@scene  = Qt::GraphicsScene.new
		super()

                @plans  = plans.dup
                @display_plan_bounding_boxes = false

                @display_policy    = :explicit
		@graphics          = Hash.new
		@selected_objects   = ValueSet.new
		@visible_objects   = ValueSet.new
		@flashing_objects  = Hash.new
		@arrows            = Hash.new
                @free_arrows       = Array.new
		@enabled_relations = Set.new
		@layout_relations  = Set.new
		@relation_colors   = Hash.new
		@relation_pens     = Hash.new(Qt::Pen.new(Qt::Color.new(ARROW_COLOR)))
		@relation_brushes  = Hash.new(Qt::Brush.new(Qt::Color.new(ARROW_COLOR)))
		@current_color     = 0

		@signal_arrows     = []
		@hide_finalized	   = true
                @layout_options    = Hash.new

		default_colors = {
		    Roby::TaskStructure::Hierarchy => 'grey',
		    Roby::TaskStructure::PlannedBy => '#32ba21',
		    Roby::TaskStructure::ExecutionAgent => '#5d95cf',
		    Roby::TaskStructure::ErrorHandling => '#ff2727'
		}
		default_colors.each do |rel, color|
		    update_relation_color(rel, color)
		end

		relation_pens[Roby::EventStructure::Signal]    = Qt::Pen.new(Qt::Color.new('black'))
		relation_brushes[Roby::EventStructure::Signal] = Qt::Brush.new(Qt::Color.new('black'))
		relation_pens[Roby::EventStructure::Forwarding]    = Qt::Pen.new(Qt::Color.new('black'))
		relation_pens[Roby::EventStructure::Forwarding].style = Qt::DotLine
		relation_brushes[Roby::EventStructure::Forwarding] = Qt::Brush.new(Qt::Color.new('black'))
		relation_brushes[Roby::EventStructure::Forwarding].style = Qt::DotLine


                enable_relation(Roby::TaskStructure::Dependency)
                enable_relation(Roby::TaskStructure::ExecutionAgent)
                enable_relation(Roby::TaskStructure::PlannedBy)
	    end

            def save_options
                options = Hash.new
                options['enabled_relations'] = @enabled_relations.map(&:name)
                options['show_ownership'] = show_ownership
                options['hide_finalized'] = hide_finalized
                options['removed_prefixes'] = removed_prefixes.dup
                options['hidden_labels'] = hidden_labels.dup
                options['display_policy'] = display_policy
                options
            end

            def apply_options(options)
                if enabled_relations = options['enabled_relations']
                    enabled_relations.each do |name|
                        rel = constant(name)
                        enable_relation(rel)
                    end
                end
                apply_simple_option('show_ownership', options)
                apply_simple_option('removed_prefixes', options)
                apply_simple_option('hide_finalized', options)
                apply_simple_option('removed_prefixes', options)
                apply_simple_option('hidden_labels', options)
                apply_simple_option('display_policy', options)
            end

            def apply_simple_option(option_name, options)
                if options.has_key?(option_name)
                    self.send("#{option_name}=", options[option_name])
                end
            end

	    def object_of(item)
                id = item.data(0).to_string
                return if !id
                id = Integer(id)

		obj, _ = graphics.find do |obj, obj_item| 
		    obj.object_id == id
		end
		obj
	    end

            def relation_of(item)
                id = item.data(0).to_string
                arrows.each do |(from, to, rel), arrow|
                    if arrow.data(0).to_string == id
                        return from, to, rel
                    end
                end
                nil
            end

	    def [](item); graphics[item] end

            # Returns a canvas object that represents this relation
	    def task_relation(from, to, rel, info)
		arrow(from, to, rel, info, TASK_LAYER)
	    end
            # Returns a canvas object that represents this relation
	    def event_relation(form, to, rel, info)
		arrow(from, to, rel, info, EVENT_LAYER)
	    end

            # Creates or reuses an arrow object to represent the given relation
	    def arrow(from, to, rel, info, base_layer)
		id = [from, to, rel]
                if !(item = arrows[id])
                    if item = last_arrows.delete(id)
                        arrows[id] = item
                    else
                        item = arrows[id] = (free_arrows.pop || scene.add_arrow(ARROW_SIZE))
                        item.z_value      = base_layer - 1
                        item.pen   = item.line.pen = relation_pens[rel]
                        item.brush = relation_brushes[rel]
                    end
                end

		RelationsDisplay.arrow_set item, self[from], self[to]
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
		objects = []
		for p in plans
		    objects.concat p.known_tasks.
			find_all { |object| displayed?(object) && regex === object.display_name(self) }
		    objects.concat p.free_events.
			find_all { |object| displayed?(object) && regex === object.display_name(self) }
		end

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
		bb.adjust(-FIND_MARGIN, -FIND_MARGIN, FIND_MARGIN, FIND_MARGIN)
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

            # True if this relation should be displayed
	    def relation_enabled?(relation); @enabled_relations.include?(relation) end
            # True if this relation should be used for layout
            #
            # See also #relation_enabled?, #layout_relation, #ignore_relation
	    def layout_relation?(relation); relation_enabled?(relation) || @layout_relations.include?(relation) end

            # Display this relation
	    def enable_relation(relation)
		return if relation_enabled?(relation)
		@enabled_relations << relation
		arrows.each do |(_, _, rel), arrow|
		    if rel == relation
			arrow.visible = true 
		    end
		end
	    end

            # The set of relations that should be displayed
	    attr_reader :enabled_relations

            # Use this relation for layout but not for display
            #
            # See also #ignore_relation
	    def layout_relation(relation)
		disable_relation(relation)
		@layout_relations << relation
	    end

            # Don't use this relation at all
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

            DISPLAY_POLICIES = [:explicit, :emitters, :emitters_and_parents]
            attr_reader :display_policy
            def display_policy=(policy)
                if !DISPLAY_POLICIES.include?(policy)
                    raise ArgumentError, "got #{policy.inspect} as a display policy, accepted values are #{DISPLAY_POLICIES.map(&:inspect).join(", ")}"
                end
                @display_policy = policy
            end

	    def displayed?(object)
                if (parent = object.display_parent) && !displayed?(parent)
                    return false
                end
                return visible_objects.include?(object)
	    end

	    def create_or_get_item(object, initial_selection)
		if !(item = graphics[object])
		    item = graphics[object] = object.display_create(self)
		    if item
                        if object.display_parent
                            item.parent_item = self[object.display_parent]
                        end

			yield(item) if block_given?

                        if initial_selection
                            selected_objects << object
                        end
		    end
                end
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
                if object.display_parent
                    add_flashing_object(object.display_parent, &block)
                end

		create_or_get_item(object, false)
	    end

            # Removes the objects added with #add_flashing_object when they
            # should be removed
	    def clear_flashing_objects
                removed_objects = []
                flashing_objects.delete_if do |object, blocks|
                    blocks.delete_if { |block| !block.call }
                    if !blocks.empty?
                        next
                    end
                    removed_objects << object
                end

                removed_objects.each do |object|
		    if item = graphics[object]
			item.visible = displayed?(object)
		    end
                end
            end

            # Sets the style on +arrow+ according to the event propagation type
            # provided in +flag+
            # 
            # +arrow+ is the graphics item representing the relation and +flag+
            # is one of the PROPAG_ constant
	    def propagation_style(arrow, flag)
		unless defined? @@propagation_styles
		    @@propagation_styles = Hash.new
		    @@propagation_styles[PROPAG_FORWARD] = 
			[Qt::Brush.new(Qt::Color.new('black')), Qt::Pen.new, (forward_pen = Qt::Pen.new)]
		    forward_pen.style = Qt::DotLine
		    @@propagation_styles[PROPAG_SIGNAL] = 
			[Qt::Brush.new(Qt::Color.new('black')), Qt::Pen.new, Qt::Pen.new]
		    @@propagation_styles[PROPAG_EMITTING] = 
			[Qt::Brush.new(Qt::Color.new('blue')), Qt::Pen.new(Qt::Color.new('blue')), (emitting_pen = Qt::Pen.new(Qt::Color.new('blue')))]
		    emitting_pen.style = Qt::DotLine
		    @@propagation_styles[PROPAG_CALLING] = 
			[Qt::Brush.new(Qt::Color.new('blue')), Qt::Pen.new(Qt::Color.new('blue')), Qt::Pen.new(Qt::Color.new('blue'))]
		end
		arrow.brush, arrow.pen, arrow.line.pen = @@propagation_styles[flag]
	    end

            def update_visible_objects
                @visible_objects = ValueSet.new

                # NOTE: we unconditionally add events that are propagated, as
                # #displayed?(obj) will filter out the ones whose task is hidden
                plans.each do |p|
                    if display_plan_bounding_boxes?
                        visible_objects << p
                    end
                    p.emitted_events.each do |flags, object|
                        visible_objects << object
                    end
                    p.propagated_events.each do |_, sources, to, _|
                        sources.each do |src|
                            visible_objects << src
                        end
                        visible_objects << to
                    end
                end

                if display_policy == :explicit
                    visible_objects.merge(selected_objects)

                elsif display_policy == :emitters || display_policy == :emitters_and_parents
                    # Make sure that the event's tasks are added to
                    # visible_objects as well
                    visible_objects.dup.each do |obj|
                        if parent = obj.display_parent
                            visible_objects << parent
                        end
                    end
                end

                if display_policy == :emitters_and_parents
                    while true
                        new_visible_objects = ValueSet.new
                        Roby::TaskStructure.each_relation do |rel|
                            components = rel.reverse.generated_subgraphs(visible_objects, false)
                            components.each do |c|
                                new_visible_objects.merge(c.to_value_set - visible_objects)
                            end
                        end
                        if new_visible_objects.empty?
                            break
                        end
                        visible_objects.merge(new_visible_objects)
                    end
                    visible_objects.dup.each do |obj|
                        if obj.kind_of?(Roby::Task)
                            obj.each_relation do |rel|
                                visible_objects.merge(obj.child_objects(rel).to_value_set)
                            end
                        end
                    end
                end

                if hide_finalized
                    plans.each do |plan|
                        all_finalized = plan.finalized_tasks | plan.finalized_events
                        @visible_objects = visible_objects - all_finalized
                    end
                end
                visible_objects.delete_if do |obj|
                    filtered_out_label?(obj.display_name(self))
                end
            end

            def make_graphics_visible(object)
                object = create_or_get_item(object, false)
                object.visible = true
                object
            end

            attr_reader :current_time

            # Update the display with new data that has come from the data
            # stream. 
            #
            # It would be too complex at this stage to know if the plan has been
            # updated, so the method always returns true
	    def update(time = nil)
                # Allow time to be a Qt::DateTime object, so that we can make it
                # a slot
                if time.kind_of?(Qt::DateTime)
                    time = Time.at(Float(time.toMSecsSinceEpoch) / 1000)
                end
                enabled_relations << Roby::EventStructure::Signal << Roby::EventStructure::Forwarding

                if time
                    @current_time = time
                end

                @last_arrows, @arrows = arrows, Hash.new
                @free_arrows ||= Array.new

		update_prefixes_removal
		clear_flashing_objects

		# The sets of tasks and events know to the data stream
		all_tasks  = plans.inject(ValueSet.new) do |all_tasks, plan|
		    all_tasks.merge plan.known_tasks
		    all_tasks.merge plan.finalized_tasks
		end
		all_events = plans.inject(ValueSet.new) do |all_events, plan|
		    all_events.merge plan.free_events
		    all_events.merge plan.finalized_events
		end
                all_task_events = all_tasks.inject(ValueSet.new) do |all_task_events, task|
                    all_task_events.merge(task.bound_events.values.to_value_set)
                end

		# Remove the items for objects that don't exist anymore
		(graphics.keys.to_value_set - all_tasks - all_events - all_task_events).each do |obj|
		    selected_objects.delete(obj)
		    remove_graphics(graphics.delete(obj))
		    clear_arrows(obj)
		end

		# Create graphics items for all objects that may get displayed
                # on the canvas
                all_tasks.each do |object|
                    create_or_get_item(object, true)
		    object.each_event do |ev|
                        create_or_get_item(ev, false)
		    end
		end
                all_events.each { |ev| create_or_get_item(ev, true) }
                plans.each { |p| create_or_get_item(p, display_plan_bounding_boxes?) }

                update_visible_objects

                graphics.each do |object, item|
                    item.visible = displayed?(object)
                end

		DisplayEventGenerator.priorities.clear
		event_priority = 0
                plans.each do |p|
                    p.emitted_events.each_with_index do |(flags, object), event_priority|
                        DisplayEventGenerator.priorities[object] = event_priority
                        if displayed?(object)
                            item = graphics[object]
                            item.brush, item.pen = DisplayEventGenerator.style(object, flags)
                        end
                    end
                    p.failed_emissions.each do |generator, object|
                        if displayed?(generator)
                            item = graphics[generator]
                            item.brush, item.pen = DisplayEventGenerator.style(generator, FAILED_EMISSION)
                        end
                    end
                end
		
                plans.each do |p|
                    p.propagated_events.each do |_, sources, to, _|
                        sources.each do |from|
                            if !DisplayEventGenerator.priorities.has_key?(from)
                                DisplayEventGenerator.priorities[from] = (event_priority += 1)
                            end
                            if !DisplayEventGenerator.priorities.has_key?(to)
                                DisplayEventGenerator.priorities[to] = (event_priority += 1)
                            end
                        end
                    end
                end

		[all_tasks, all_events, plans].each do |object_set|
		    object_set.each do |object|
                        graphics = self.graphics[object]
                        if graphics.visible?
                            object.display(self, graphics)
                        end
		    end
		end

		# Update arrow visibility
		arrows.each do |(from, to, rel), item|
                    next if !@enabled_relations.include?(rel)
		    item.visible = (displayed?(from) && displayed?(to))
		end

		# Layout the graph
		layouts = plans.find_all { |p| p.root_plan? }.
		    map do |p| 
			dot = Layout.new
			dot.layout(self, p, layout_options)
			dot
		    end
		layouts.each { |dot| dot.apply }

		# Display the signals
		signal_arrow_idx = -1
                plans.each do |p|
                    p.propagated_events.each_with_index do |(flag, sources, to), signal_arrow_idx|
                        sources.each do |from|
                            relation =
                                if (flag & PROPAG_FORWARD) || (flag & PROPAG_EMITTING)
                                    Roby::EventStructure::Forwarding
                                else
                                    Roby::EventStructure::Signal
                                end

                            arrow = arrow(from, to, relation, nil, EVENT_PROPAGATION_LAYER)
                            propagation_style(arrow, flag)
                        end
                    end
                end
                arrows.each do |_, item|
                    item.visible = true
                end
                @free_arrows = last_arrows.values
                free_arrows.each do |item|
                    item.visible = false
                end
                last_arrows.clear

                true
            #rescue Exception => e
            #    message = "<html>#{e.message.gsub('<', '&lt;').gsub('>', '&gt;')}<ul><li>#{e.backtrace.join("</li><li>")}</li></ul></html>"
            #    Qt::MessageBox.critical nil, "Display failure", message
	    end

	    def remove_graphics(item, scene = nil)
		return unless item
		scene ||= item.scene
		scene.remove_item(item) if scene
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
                free_arrows.clear
                last_arrows.clear
		graphics.clear

		signal_arrows.each do |arrow|
		    arrow.visible = false
		end

		selected_objects.clear
		visible_objects.clear
		flashing_objects.clear
		scene.update(scene.scene_rect)
	    end
	end
    end
    end
end

