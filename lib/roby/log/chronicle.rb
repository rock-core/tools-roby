require 'roby/log/data_stream'
require 'roby/log/relations'

class Chronicle < Roby::Log::DataDecoder
end

module Roby
    module Log
	class ChronicleDisplay < Qt::Object

	    Line = Struct.new :y, :item, :graphic_group

	    include DataDisplay
	    decoder PlanRebuilder

	    include TaskDisplaySupport

	    attr_reader :scene
	    attr_reader :signalled_events
	    attr_reader :execution_events
	    attr_reader :graphic_stack
	    attr_reader :graphic_objects
	    attr_reader :last_event_graphics
	    attr_reader :time_scale

	    def initialize
		@scene  = Qt::GraphicsScene.new
		super()

		@main = Qt::GraphicsView.new(@scene)
		main.resize 500, 500

		@signalled_events    = []
		@execution_events    = []
		@graphic_stack       = []
		@graphic_objects     = Hash.new
		@last_event_graphics = Hash.new
		self.show_ownership = false

		connect(main.horizontalScrollBar, SIGNAL('sliderReleased()'), self, SLOT('hscroll()'))

		@time_scale = 100.0
	    end

	    def hscroll
		left_side = main.mapToScene(0, 0).x

		graphic_stack.each do |line|
		    item = line.item
		    next unless item.kind_of?(Roby::Task::DRoby)

		    graphics = graphic_objects[item]

		    task_x   = graphics.pos.x
		    text_pos = graphics.text.pos
		    text_pos.x = if task_x < left_side
				     left_side
				 else task_x
				 end
		    text_pos.x -= task_x

		    graphics.text.pos = text_pos
		end
	    end
	    slots 'hscroll()'

	    def time_to_display(time)
		(time - decoder.start_time) * time_scale
	    end

	    def create_line(item)
		group = scene.create_item_group([])
		graphic_stack << Line.new(0, item, group)
		group
	    end

	    def create_or_get_task(item, time)
		unless g = graphic_objects[item]
		    pos_x = time_to_display(time)

		    g = graphic_objects[item] = item.display_create(self)
		    class << g; attr_accessor :start_time end
		    g.start_time = time
		    g.rect = Qt::RectF.new(0, 0, 0, Log::DEFAULT_TASK_HEIGHT)
		    g.move_by pos_x, 0
		    group = create_line(item)
		    group.add_to_group g
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

		scrollbar = main.horizontalScrollBar
		following_execution = (scrollbar.maximum == scrollbar.value)

		decoder.plans.each_key do |plan|
		    next unless plan.root_plan?
		    (plan.finalized_tasks | plan.finalized_events).each do |object|
			if line = line_of(object)
			    graphic_objects.delete(object)
			    scene.removeItem(graphic_stack[line].graphic_group)
			    graphic_stack.delete_at(line)
			end
		    end
		end

		execution_events.each do |flag, time, event|
		    graphics = event.display_create(self)

		    if event.respond_to?(:task)
			task_graphics = create_or_get_task(event.task, time)

			# Move the right edge of the task to reflect that it is
			# still running. Then, make sure the rectangle can
			# contain the event graphics
			rect = task_graphics.rect
			expected_height = graphics.children_bounding_rect.height + Log::TASK_EVENT_SPACING
			if rect.height < expected_height
			    dy = expected_height - rect.height
			    rect.height = expected_height
			    task_graphics.text.move_by 0, dy
			end
			task_graphics.rect = rect
			event.task.last_event = [time, event]
			line = line_of(event.task)
		    elsif !(line = line_of(event))
			group = create_line(event)
			line = (graphic_stack.size - 1)
		    end

		    graphics.move_by time_to_display(time), 
			graphic_stack[line].y + Log::EVENT_CIRCLE_RADIUS + Log::TASK_EVENT_SPACING

		    # Try to handle too-near events gracefully
		    old_flag, old_graphics = last_event_graphics[event]
		    if old_flag
			flag = 2 if old_flag == 0 && flag == 1
			if old_graphics.text.bounding_rect.right > graphics.text.bounding_rect.left
			    old_graphics.text.hide
			end
		    end
		    last_event_graphics[event] = [flag, graphics]

		    graphics.brush, graphics.pen = 
			case flag
			when 0: EventGeneratorDisplay.pending_style
			when 1: EventGeneratorDisplay.fired_style
			when 2
			    [EventGeneratorDisplay.fired_style[0], 
				EventGeneratorDisplay.pending_style[1]]
			end
		    graphic_stack[line].graphic_group.add_to_group graphics
		end

		decoder.tasks.each_key do |task|
		    next unless task_graphics = graphic_objects[task]

		    old_state = task.displayed_state
		    task.update_graphics(self, task_graphics)

		    state = task.current_state
		    rect = task_graphics.rect

		    last_time = if state != old_state && (state == :success || state == :finished)
				    task.last_event[0]
				else decoder.time
				end
		    rect.width = time_to_display(last_time) - time_to_display(task_graphics.start_time)
		    task_graphics.rect = rect
		end

		if following_execution
		    scrollbar.value = scrollbar.maximum
		    hscroll
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
		execution_events << [0, time, local_event(generator)]
	    end
	    def generator_fired(time, generator, event_id, event_time, event_context)
		generator = local_event(generator)
		execution_events << [1, event_time, generator]
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


