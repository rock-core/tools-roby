require 'roby/log/data_stream'
require 'roby/log/relations'
require 'roby/log/gui/chronicle_view'

module Roby
    module LogReplay
	class ChronicleDisplay < Qt::Object

	    # y:: the Y of this line in the graphics scene
	    # item:: the main item, either a free event or a task
	    # graphic_items:: the array of graphic items
	    # graphics_group:: a Qt::GraphicsGroup object holding all graphic objects for this line
	    Line = Struct.new :y, :item, :graphic_items, :graphic_group, :start_time
	    class Line
		def add(graphic_item, time)
		    class << graphic_item; attr_accessor :time end
		    graphic_item.time = time
		    graphic_group.add_to_group graphic_item

		    if graphic_items.empty?
			self.start_time = time
		    end
		    graphic_items << graphic_item
		end
	    end

	    include LogTools::DataDisplay
	    decoder PlanRebuilder

	    include TaskDisplaySupport

	    attr_reader :scene
	    attr_reader :ui

	    attr_reader :signalled_events
	    attr_reader :execution_events
	    attr_reader :graphic_stack
	    attr_reader :graphic_objects
	    attr_reader :last_event_graphics
	    attr_reader :time_scale

	    attr_predicate :display_follows_execution?, true
	    attr_predicate :display_follows_new_tasks?, true

	    def initialize
		@scene  = Qt::GraphicsScene.new
		super()

		@main = Qt::MainWindow.new
		main.resize 500, 500
		@ui = Ui::ChronicleView.new
		ui.setupUi(self, main)
		ui.graphics.scene = @scene

		@signalled_events    = []
		@execution_events    = []
		@graphic_stack       = []
		@graphic_objects     = Hash.new
		@last_event_graphics = Hash.new
		self.show_ownership = false

		connect(ui.graphics.horizontalScrollBar, SIGNAL('valueChanged(int)'), self, SLOT('hscroll()'))
		connect(ui.graphics.verticalScrollBar, SIGNAL('valueChanged(int)'), self, SLOT('vscroll()'))

		@time_scale = 100.0
	    end

	    def time_scale=(new_value)
		@time_scale = new_value

		# For now, we don't relayout event labels
		graphic_stack.each do |line_info|
		    base_x = time_to_display(line_info.start_time)

		    line_info.graphic_items.each do |g|
			g.set_pos(time_to_display(g.time), g.pos.y)
		    end
		end

		# call update to update the task width
		update
	    end

	    def vscroll(user = true)
		if user
		    scrollbar = ui.graphics.verticalScrollBar
		    @display_follows_new_tasks = (scrollbar.maximum == scrollbar.value)
		end
	    end
	    slots 'vscroll()'

	    def hscroll(user = true)
		left_side = ui.graphics.mapToScene(0, 0).x

		if user
		    scrollbar = ui.graphics.horizontalScrollBar
		    @display_follows_execution = (scrollbar.maximum == scrollbar.value)
		end

		graphic_stack.each do |line|
		    item = line.item
		    next unless item.kind_of?(Roby::Task::DRoby)

		    graphics = graphic_objects[item]
		    dx = graphics.pos.x - left_side
		    if dx <= 0
			graphics.text.set_pos(-dx, graphics.text.pos.y)
		    else
			graphics.text.set_pos(0, graphics.text.pos.y)
		    end
		end
	    end
	    slots 'hscroll()'

	    def time_to_display(time)
		(time - decoder.start_time) * time_scale
	    end

	    def create_line(item)
		group = scene.create_item_group([])
		graphic_stack << (new_line = Line.new(0, item, [], group))
		new_line
	    end

	    def create_or_get_task(item, time)
		unless g = graphic_objects[item]
		    pos_x = time_to_display(time)

		    g = graphic_objects[item] = item.display_create(self)
		    g.rect = Qt::RectF.new(0, 0, 0, Log::DEFAULT_TASK_HEIGHT)
		    g.move_by pos_x, 0
		    line = create_line(item)
		    line.add g, time
		end
		g
	    end

	    def line_of(object)
		graphic_stack.each_with_index do |line, i|
		    return i if line.item == object
		end
		nil
	    end

	    def stream=(stream)
		super

		# Initialize the set of running tasks
		update_prefixes_removal
		decoder.tasks.each_key do |task|
		    if task.current_state == :started
			create_or_get_task(task, decoder.time)
		    end
		end
	    end


	    def append_event(task, event)
		index = line_of(task)
		create_or_get_item(event, index)
	    end

	    def update
		update_prefixes_removal

		execution_events.each do |flags, time, event|
		    graphics = event.display_create(self)
		    graphics.move_by time_to_display(time), 0
		    y_offset = Log::EVENT_CIRCLE_RADIUS + Log::TASK_EVENT_SPACING

		    if event.respond_to?(:task)
			task_graphics = create_or_get_task(event.task, time)
			line = line_of(event.task)

			# Check that the event labels to not collide. If it is
			# the case, move the current label at the bottom of the
			# last label found
			line_info = graphic_stack[line]
			if line_info.graphic_items.size > 1
			    last_event = line_info.graphic_items[-1]
			    last_br    = last_event.text.scene_bounding_rect
			    current_br = graphics.text.scene_bounding_rect
			    if last_br.right > current_br.left
				if event.task.last_event[1] == event
				    last_event.text.hide
				else
				    graphics.text.set_pos(0, last_br.bottom - last_event.scene_pos.y)
				end
			    end
			end

			# Move the right edge of the task to reflect that it is
			# still running. Then, make sure the rectangle can
			# contain the event graphics
			expected_height = graphics.text.bounding_rect.bottom + y_offset
			if expected_height > task_graphics.rect.height
			    task_graphics.set_rect(0, 0, time_to_display(time) - time_to_display(line_info.start_time), expected_height)
			    task_graphics.text.set_pos(task_graphics.text.pos.x, expected_height)
			end
			event.task.last_event = [time, event]

		    elsif !(line = line_of(event))
			group = create_line(event)
			line = (graphic_stack.size - 1)
		    end

		    line_info = graphic_stack[line]
		    graphics.move_by 0, line_info.y + y_offset

		    # Try to handle too-near events gracefully
		    #old_flag, old_graphics = last_event_graphics[event]
		    #if old_flag
		    #    flag = 2 if old_flag == 0 && flag == 1
		    #    if old_graphics.text.bounding_rect.right > graphics.text.bounding_rect.left
		    #        old_graphics.text.hide
		    #    end
		    #end
		    #last_event_graphics[event] = [flag, graphics]

		    graphics.brush, graphics.pen = EventGeneratorDisplay.style(event, flags)
		    if flags & EVENT_EMITTED == 1
			graphics.z_layer += 1
		    end
		    line_info.add graphics, time
		end

		removed_objects = (graphic_objects.keys - decoder.tasks.keys - decoder.events.keys)
		removed_objects.each do |obj|
		    if line = line_of(obj)
			graphic_objects.delete(obj)
			scene.remove_item graphic_stack[line].graphic_group
			graphic_stack.delete_at(line)
		    end
		end

		decoder.tasks.each_key do |task|
		    next unless task_graphics = graphic_objects[task]
		    line_info = graphic_stack[line_of(task)]

		    old_state = task.displayed_state
		    task.update_graphics(self, task_graphics)

		    state = task.current_state
		    rect = task_graphics.rect

		    last_time = if state == :success || state == :finished
				    task.last_event[0]
				else decoder.time
				end
		    task_graphics.set_rect(0, 0, time_to_display(last_time) - time_to_display(line_info.start_time), rect.height)
		end

		if display_follows_execution?
		    scrollbar = ui.graphics.horizontalScrollBar
		    scrollbar.value = scrollbar.maximum
		    hscroll(false)
		end

		if display_follows_new_tasks?
		    scrollbar = ui.graphics.verticalScrollBar
		    scrollbar.value = scrollbar.maximum
		end

		# layout lines
		y = 0
		graphic_stack.each do |line|
		    offset = y - line.y
		    if offset != 0
			line.y = y
			line.graphic_group.move_by 0, offset
		    end

		    br = line.graphic_group.bounding_rect | line.graphic_group.children_bounding_rect
		    y += br.bottom + Log::TASK_EVENT_SPACING
		end

		execution_events.clear
		signalled_events.clear
	    end

	    def local_task(obj);   decoder.local_task(obj) end
	    def local_event(obj);  decoder.local_event(obj) end
	    def local_plan(obj);   decoder.local_plan(obj) end
	    def local_object(obj); decoder.local_object(obj) end

	    def generator_called(time, generator, context)
		execution_events << [EVENT_CALLED, time, local_event(generator)]
	    end
	    def generator_fired(time, generator, event_id, event_time, event_context)
		generator = local_event(generator)
		execution_events << [EVENT_EMITTED, event_time, generator]
	    end
	    def generator_signalling(time, flag, from, to, event_id, event_time, event_context)
		signalled_events << [flag, local_event(from), local_event(to), event_id]
	    end
	    def generator_forwarding(time, flag, from, to, event_id, event_time, event_context)
		signalled_events << [flag, local_event(from), local_event(to), event_id]
	    end
	end
    end
end


