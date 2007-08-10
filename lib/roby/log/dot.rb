require 'roby/distributed/protocol'
require 'roby/log'
require 'tempfile'
require 'fileutils'

module Roby
    module LoggedPlan
	attr_accessor :layout_level
	def all_events(display)
	    known_tasks.inject(free_events.dup) do |events, task|
		if display.displayed?(task)
		    events.merge(task.events.values.to_value_set)
		else
		    events
		end
	    end
	end

	attr_reader :dot_id
	def to_dot(display, io, level)
	    @layout_level = level
	    id = io.layout_id(self)
	    @dot_id = "plan_#{id}"
	    io << "subgraph cluster_#{dot_id} {\n"
	    (known_tasks | finalized_tasks | free_events | finalized_events).
		each do |obj|
		    obj.to_dot(display, io) if display.displayed?(obj)
		end

	    io << "};\n"

	    transactions.each do |trsc|
		trsc.to_dot(display, io, level + 1)
	    end

	    relations_to_dot(display, io, TaskStructure, known_tasks)
	    relations_to_dot(display, io, EventStructure, all_events(display))
	end

	def each_displayed_relation(display, space, objects)
	    space.relations.each do |rel|
		next unless display.relation_enabled?(rel)

		objects.each do |from|
		    next unless display.displayed?(from)
		    unless display[from]
			Roby::Log.warn "no display item for #{from} in #each_displayed_relation"
			next
		    end

		    from.each_child_object(rel) do |to|
			next unless display.displayed?(to)
			unless display[to]
			    Roby::Log.warn "no display item for child in #{from} <#{rel}> #{to} in #each_displayed_relation"
			    next
			end

			yield(rel, from, to)
		    end
		end
	    end
	end

	def relations_to_dot(display, io, space, objects)
	    each_displayed_relation(display, space, objects) do |rel, from, to|
		from_id, to_id = from.dot_id, to.dot_id
		if from_id && to_id
		    io << "  #{from_id} -> #{to_id}\n"
		else
		    Roby::Log.warn "ignoring #{from}(#{from.object_id} #{from_id}) -> #{to}(#{to.object_id} #{to_id}) in #{rel} in #{caller(1).join("\n  ")}"
		end
	    end
	end

	def layout_relations(positions, display, space, objects)
	    each_displayed_relation(display, space, objects) do |rel, from, to|
		display.task_relation(from, to, rel, from[to, rel])
	    end
	end

	# The distance from the root plan
	attr_reader :depth

	# Computes the plan depths and max_depth for this plan and all its
	# children. +depth+ is this plan depth
	#
	# Returns max_depth
	def compute_depth(depth)
	    @depth = depth
	    child_depth = transactions.
		map { |trsc| trsc.compute_depth(depth + 1) }.
		max
	    child_depth || depth
	end
	
	def apply_layout(bounding_rects, positions, display, max_depth = nil)
	    max_depth ||= compute_depth(0)

	    if rect = bounding_rects[dot_id]
		item = display[self]
		item.z_value = Log::PLAN_LAYER + depth - max_depth
		item.set_rect *rect
	    else
		Roby::Log.warn "no bounding rectangle for #{self} (#{dot_id})"
	    end


	    (known_tasks | finalized_tasks | free_events | finalized_events).
		each do |obj|
		    obj.apply_layout(positions, display)
		end

	    transactions.each do |trsc|
		trsc.apply_layout(bounding_rects, positions, display, max_depth)
	    end
	    layout_relations(positions, display, TaskStructure, known_tasks)
	    layout_relations(positions, display, EventStructure, all_events(display))
	end
    end

    module LoggedPlanObject
	attr_reader :dot_id

	def dot_label(display); display_name(display) end

	# Adds the dot definition for this object in +io+
	def to_dot(display, io)
	    return unless display.displayed?(self)
	    @dot_id ||= "plan_object_#{io.layout_id(self)}"
	    io << "  #{dot_id}[label=\"#{dot_label(display).split("\n").join('\n')}\"];\n"
	end

	# Applys the layout in +positions+ to this particular object
	def apply_layout(positions, display)
	    return unless display.displayed?(self)
	    if p = positions[dot_id]
		raise "no graphics for #{self}" unless graphics_item = display[self]
		graphics_item.pos = p
	    else
		STDERR.puts "WARN: #{self} has not been layouted"
	    end
	end
    end

    class PlanObject::DRoby
	include LoggedPlanObject
    end

    class TaskEventGenerator::DRoby
	def dot_label(display); symbol.to_s end
	def dot_id; task.dot_id end
    end

    module LoggedTask
	include LoggedPlanObject
	def dot_label(display)
	    event_names = events.values.find_all { |ev| display.displayed?(ev) }.
		map { |ev| ev.dot_label(display) }.
		join(" ")

	    own = super
	    if own.size > event_names.size then own
	    else event_names
	    end
	end
    end

    module Log
	class Layout
	    @@bkpindex = 0

	    def layout_id(object)
		id = Object.address_from_id(object.object_id).to_s
		object_ids[id] = object
		id
	    end

	    attribute(:object_ids) { Hash.new }
	    attr_reader :dot_input

	    def <<(string); dot_input << string end
	    def layout(display, plan)
		@@index ||= 0
		@@index += 1

		# Dot input file
		@dot_input  = Tempfile.new("roby_dot")
		# Dot output file
		dot_output = Tempfile.new("roby_layout")

		dot_input << "digraph relations {\n"
		display.layout_options.each do |k, v|
		    dot_input << "  #{k}=#{v};\n"
		end
		plan.to_dot(display, self, 0)

		# Take the signalling into account for the layout
		display.signalled_events.each do |_, from, to, _|
		    from_id, to_id = from.dot_id, to.dot_id
		    if from_id && to_id
			dot_input << "  #{from.dot_id} -> #{to.dot_id}\n"
		    end
		end

		dot_input << "\n};"
		dot_input.flush

		# Make sure the GUI keeps being updated while dot is processing
		FileUtils.cp dot_input.path, "/tmp/dot-input-#{@@index}.dot"
		system("#{display.layout_method} #{dot_input.path} > #{dot_output.path}")
		#pid = fork do
		#    exec("#{display.layout_method} #{dot_input.path} > #{dot_output.path}")
		#end
		#while !Process.waitpid(pid, Process::WNOHANG)
		#    if Qt::Application.has_pending_events
		#	Qt::Application.process_events
		#    else
		#	sleep(0.05)
		#    end
		#end
		FileUtils.cp dot_output.path, "/tmp/dot-output-#{@@index}.dot"

		# Load only task bounding boxes from dot, update arrows later
		current_graph_id = nil
		bounding_rects = Hash.new
		object_pos     = Hash.new
		lines = File.open(dot_output.path) { |io| io.readlines  }
		full_line = ""
		lines.each do |line|
		    line.chomp!
		    full_line << line
		    if line[-1] == ?\\
			full_line.chop!
			next
		    end

		    case full_line
		    when /((?:\w+_)+\d+) \[.*pos="(\d+),(\d+)"/
			object_pos[$1] = Qt::PointF.new(Integer($2) * display.layout_scale, Integer($3) * display.layout_scale)
		    when /subgraph cluster_(plan_\d+)/
			current_graph_id = $1
		    when /graph \[bb="(\d+),(\d+),(\d+),(\d+)"\]/
			bb = [$1, $2, $3, $4].map do |c|
			    c = Integer(c) * display.layout_scale
			end
			bounding_rects[current_graph_id] = [bb[0], bb[1], bb[2] - bb[0], bb[3] - bb[1]]
		    end
		    full_line = ""
		end

		graph_bb = bounding_rects.delete(nil)
		bounding_rects.each_value do |coords|
		    coords[0] -= graph_bb[0]
		    coords[1] = graph_bb[1] - coords[1] - coords[3]
		end
		object_pos.each do |id, pos|
		    pos.x -= graph_bb[0]
		    pos.y = graph_bb[1] - pos.y
		end

		@display         = display
		@plan            = plan
		@object_pos      = object_pos
		@bounding_rects  = bounding_rects

	    ensure
		dot_input.close!  if dot_input
		dot_output.close! if dot_output
	    end

	    attr_reader :bounding_rects, :object_pos, :display, :plan
	    def apply
		plan.apply_layout(bounding_rects, object_pos, display)
	    end
	end
    end
end
