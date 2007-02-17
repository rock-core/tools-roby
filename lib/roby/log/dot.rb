require 'roby/log'
require 'tempfile'
require 'fileutils'
module Roby::Marshallable
    class Task
	def dot(layout); layout.task(self) end
    end
    class Transaction
	def dot(layout); layout.plan(source_id, layout.display.plans[source_id]) end
    end
    class TransactionProxy
	def dot(layout); layout.task(self) end
    end
end

module Roby
    module Log::Display
	Marshallable = Roby::Marshallable
	class Plan
	    attr_accessor :layout_level
	    def all_events
		known_tasks.inject(free_events.dup) do |events, task|
		    if task.displayed?
			events.merge(task.events)
		    else
			events
		    end
		end
	    end

	    def to_dot(io, level)
		@layout_level = level
		id = io.layout_id(self)
		io << "subgraph cluster_plan_#{id} {\n"
		known_tasks.each { |t| t.to_dot(io) }
		free_events.each { |e| e.to_dot(io) }
		io << "};\n"

		transactions.each do |trsc|
		    trsc.to_dot(io, level + 1)
		end

		relations_to_dot(io, TaskStructure, known_tasks)
		relations_to_dot(io, EventStructure, all_events)
	    end

	    def each_displayed_relation(space, objects)
		space.relations.each do |rel|
		    objects.each do |from|
			next unless from.displayed?

			from.each_child_object(rel) do |to|
			    next unless to.displayed?
			    yield(rel, from, to)
			end
		    end
		end
	    end

	    def relations_to_dot(io, space, objects)
		each_displayed_relation(space, objects) do |rel, from, to|
		    from_id = from.dot_id
		    to_id   = to.dot_id
		    if from_id && to_id
			io << "  #{from_id} -> #{to_id};"
		    else
			STDERR.puts "WARN ignoring #{from}(#{from.object_id} #{from.remote_object}) -> #{to}(#{to.object_id} #{to.remote_object}) in #{rel} in #{caller(1).join("\n  ")}"
		    end
		end
	    end

	    def layout_relations(positions, space, objects)
		each_displayed_relation(space, objects) do |rel, from, to|
		    data, arrow = from[to, rel]
		    if arrow
			Display.arrow_set arrow, from.graphics_item, to.graphics_item
			arrow.show
		    else
			STDERR.puts "No arrow for #{from} -> #{to} in #{rel}"
		    end
		end
	    end
	    
	    def apply_layout(positions)
		known_tasks.each { |t| t.apply_layout(positions) }
		free_events.each { |e| e.apply_layout(positions) }
		transactions.each do |trsc|
		    trsc.apply_layout(positions)
		end
		layout_relations(positions, TaskStructure, known_tasks)
		layout_relations(positions, EventStructure, all_events)
	    end
	end

	class Distributed::MarshalledPlanObject
	    attr_reader :dot_id

	    # Adds the dot definition for this object in +io+
	    def to_dot(io)
		return unless displayed?
		@dot_id = io.layout_id(self)
		io << "  #{dot_id}[label=\"#{display_name.split("\n").join('\n')}\"];\n"
	    end

	    # Applys the layout in +positions+ to this particular object
	    def apply_layout(positions)
		return unless displayed?
		if p = positions[dot_id]
		    graphics_item.pos = p
		else
		    STDERR.puts "WARN: #{self} has not been layouted"
		end
	    end
	end

	class Distributed::MarshalledTaskEventGenerator
	    def dot_id; task.dot_id end
	end
	class Distributed::MarshalledTask
	end

	class Distributed::MarshalledRemoteTransactionProxy
	    def dot_id; end
	    def to_dot(io); end
	    def apply_layout(positions); end
	end

	class Layout
	    @@bkpindex = 0

	    def layout_id(object)
		object = object.remote_object
		uri = object.__drburi.gsub(/[.:\/]/, '_')
		ref = object.__drbref
		id  = "#{uri}_#{ref}"
		object_ids[id] = object
		id
	    end

	    attribute(:object_ids) { Hash.new }
	    attr_reader :dot_input

	    def <<(string); dot_input << string end
	    def layout(plan, scale)
		# Dot input file
		@dot_input  = Tempfile.new("roby_dot")
		# Dot output file
		dot_output = Tempfile.new("roby_layout")

		dot_input << "digraph relations {\n" 
		#+
		#       "  nslimit=4.0;\n" +
		#       "  fslimit=4.0;\n"

		plan.to_dot(self, 0)
		dot_input << "\n};"
		dot_input.flush
		FileUtils.cp(dot_input.path, "/tmp/dot_layout.input.#{@@bkpindex += 1}")
		system("dot #{dot_input.path} > #{dot_output.path}")
		FileUtils.cp(dot_output.path, "/tmp/dot_layout.output.#{@@bkpindex}")

		# Load only task bounding boxes from dot, update arrows later
		graph_bb   = nil
		object_pos = Hash.new
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
		    when /([^\s]+_\d+) \[.*pos="(\d+),(\d+)"/
			x, y = Integer($2), Integer($3)
			object_pos[$1] = Qt::PointF.new(x * scale, y * scale)
		    when /bb="(\d+),(\d+),(\d+),(\d+)"/
			bb = [$1, $2, $3, $4].map(&method(:Integer))
			if !graph_bb
			    graph_bb = bb.map { |i| i * scale }
			end
		    end
		    full_line = ""
		end
		return unless graph_bb

		plan.apply_layout(object_pos)

	    ensure
		dot_input.close!  if dot_input
		dot_output.close! if dot_output
	    end
	end
    end
end
