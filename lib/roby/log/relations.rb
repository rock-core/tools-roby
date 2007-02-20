require 'Qt4'
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

		text.parent_item = circle
		text_width   = text.bounding_rect.width
		text.pos = Qt::PointF.new(-text_width / 2, 0)
		circle.text = text
		circle
	    end
	    def display(display, graphics_item)
		text      = graphics_item.text
		old_width = text.text_width
		text.plain_text = display_name
		text.move_by((text.text_width - old_width) / 2, 0)

		super
	    end
	end

	class Distributed::MarshalledTaskEventGenerator
	    def display_parent; task end
	    def display_name; symbol.to_s end
	end

	class Distributed::MarshalledTask
	    def layout_events(display)
		graphics_item = display[self]

		width, height = 0, 0
		if display.display_events?
		    events.each do |e|
			e  = display[e]
			br = (e.bounding_rect | e.children_bounding_rect)
			w, h = br.width, br.height
			height = h if h > height
			width += w
		    end
		    width  += TASK_EVENT_SPACING * (events.size + 1)
		    height += TASK_EVENT_SPACING

		    x = -width  / 2 + TASK_EVENT_SPACING
		    events.each do |e|
			e  = display[e]
			br = (e.bounding_rect | e.children_bounding_rect)
			w  = br.width
			e.pos = Qt::PointF.new(x + w / 2, -br.height / 2 + EVENT_CIRCLE_RADIUS + TASK_EVENT_SPACING)
			x += w + TASK_EVENT_SPACING
		    end
		else
		    width = DEFAULT_TASK_WIDTH
		    height = DEFAULT_TASK_HEIGHT
		end

		coords = Qt::RectF.new -(width / 2), -(height / 2), width, height
		graphics_item.rect = coords
		text = graphics_item.text
		text.pos = Qt::PointF.new(- text.bounding_rect.width / 2, height / 2 + TASK_EVENT_SPACING)
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
		model_name = if model.respond_to?(:remote_name)
				 model.remote_name
			     else model.name
			     end

		"#{model_name}\n0x#{Object.address_from_id(remote_object.__drbref).to_s(16)}"
		#unless arguments.empty?
		#    name += "\n " + arguments.map { |k, v| "#{k}: #{v}" }.join("\n ")
		#end
	    end

	    def display_create(scene)
		rect = scene.add_rect Qt::RectF.new(0, 0, 0, 0)
		text = scene.add_text display_name
		rect.brush = Qt::Brush.new(TASK_COLORS[:pending])
		rect.pen = Qt::Pen.new(TASK_COLORS[:pending])
		text.parent_item = rect
		rect.singleton_class.class_eval { attr_accessor :text }
		rect.text = text
		rect
	    end
	    def display(display, graphics_item)
		if flags[:finished]
		    if flags[:success]
			graphics_item.brush = Qt::Brush.new(TASK_COLORS[:success])
		    else
			graphics_item.brush = Qt::Brush.new(TASK_COLORS[:failed])
		    end
		elsif flags[:started]
		    graphics_item.brush = Qt::Brush.new(TASK_COLORS[:started])
		end
		super
		layout_events(display)
	    end
	end
	class Distributed::MarshalledRemoteTransactionProxy
	    include DirectedRelationSupport

	    def events; [] end

	    def display_parent; end
	    def display_name; name end
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

	class RelationsDisplay < Qt::Object
	    def splat?; true end
	    attr_accessor :data_source
	    attr_reader :graphics
	    attr_reader :arrows
	    attr_reader :ui, :scene
	    def view; ui.graphics end

	    def initialize
		@scene = Qt::GraphicsScene.new
		super()

		@main_widget = Qt::Widget.new
		@ui    = Ui::RelationsView.new
		ui.setupUi(@main_widget)
		@main_widget.show
		view.scene = scene
		
		@graphics = Hash.new
		@arrows = Hash.new
		@enabled_relations = Set.new
		@layout_relations = Set.new
		@relation_colors = Hash.new
		@current_color = 0

		view.resize 500, 500
	    end

	    def [](item); graphics[item.remote_object] end
	    def arrow(from, to, rel, info)
		id = [from.remote_object, to.remote_object, rel]
		unless item = arrows[id]
		    item = (arrows[id] ||= scene.add_arrow(ARROW_SIZE))
		    item.z_value = 1
		    color = Qt::Color.new(relation_color(rel))
		    item.pen = item.line.pen = Qt::Pen.new(color)
		    item.brush = Qt::Brush.new(color)
		end
		Log.arrow_set item, self[from], self[to]
	    end

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

	    def displayed?(object)
		if item = graphics[object.remote_object]
		    graphics[object.remote_object].visible?
		end
	    end
	    def display_events?
		enabled_relations.find { |rel| rel.name =~ /EventStructure/ }
	    end

	    def update
		data_source.tasks.each_value  { |task| graphics[task.remote_object] ||= task.display_create(scene) }

		data_source.events.each_value do |event| 
		    unless item = graphics[event.remote_object] 
			item = (graphics[event.remote_object] ||= event.display_create(scene))
			item.parent_item = self[event.display_parent] if event.display_parent
		    end
		    # display_create may have returned a nil object
		    if item
			item.visible = display_events?
		    end
		end
		data_source.tasks.each_value  { |task| task.display(self, graphics[task.remote_object]) }
		data_source.events.each_value { |event| event.display(self, graphics[event.remote_object]) }

		data_source.plans.find_all { |_, p| p.root_plan }.
		    each { |_, p| Layout.new.layout(self, p, 1) }
	    end

	    def remove_graphics(item, scene = nil)
		return unless item
		scene ||= item.scene
		item.children.each do |child|
		    remove_graphics(child, scene)
		end
		scene.remove_item(item) if scene
	    end
	    def removed_task_child(time, parent, rel, child)
		remove_graphics(arrows.delete([parent.remote_object, child.remote_object, rel]))
	    end
	    def removed_event_child(time, parent, rel, child)
		remove_graphics(arrows.delete([parent.remote_object, child.remote_object, rel]))
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
		event = event.remote_object
		remove_graphics(graphics.delete(event))
		clear_arrows(event)
	    end
	    def finalized_task(time, plan, task)
		task = task.remote_object
		remove_graphics(graphics.delete(task))
		clear_arrows(task)
	    end

	    def clear
		arrows.each_value(&method(:remove_graphics))
		graphics.each_value(&method(:remove_graphics))
		arrows.clear
		graphics.clear
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
    rel.view.show
    Roby::Log.replay(ARGV[0]) do |method_name, method_args|
	builder.send(method_name, *method_args) if builder.respond_to?(method_name)
	rel.send(method_name, *method_args) if rel.respond_to?(method_name)
    end
    app.exec
end

