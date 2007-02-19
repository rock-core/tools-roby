require 'roby/distributed/protocol'
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
    module Log
	Marshallable = Roby::Marshallable
	class Plan
	    attr_accessor :layout_level
	    def all_events(display)
		known_tasks.inject(free_events.dup) do |events, task|
		    if display.displayed?(task)
			events.merge(task.events)
		    else
			events
		    end
		end
	    end

	    def to_dot(display, io, level)
		@layout_level = level
		id = io.layout_id(self)
		io << "subgraph cluster_plan_#{id} {\n"
		known_tasks.each { |t| t.to_dot(display, io) }
		free_events.each { |e| e.to_dot(display, io) }
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

			from.each_child_object(rel) do |to|
			    next unless display.displayed?(to)
			    yield(rel, from, to)
			end
		    end
		end
	    end

	    def relations_to_dot(display, io, space, objects)
		each_displayed_relation(display, space, objects) do |rel, from, to|
		    from_id = from.dot_id
		    to_id   = to.dot_id
		    if from_id && to_id
			io << "  #{from_id} -> #{to_id};"
		    else
			STDERR.puts "WARN ignoring #{from}(#{from.object_id} #{from.remote_object}) -> #{to}(#{to.object_id} #{to.remote_object}) in #{rel} in #{caller(1).join("\n  ")}"
		    end
		end
	    end

	    def layout_relations(positions, display, space, objects)
		each_displayed_relation(display, space, objects) do |rel, from, to|
		    display.arrow(from, to, rel, from[to, rel])
		end
	    end
	    
	    def apply_layout(positions, display)
		known_tasks.each { |t| t.apply_layout(positions, display) }
		free_events.each { |e| e.apply_layout(positions, display) }
		transactions.each do |trsc|
		    trsc.apply_layout(positions, display)
		end
		layout_relations(positions, display, TaskStructure, known_tasks)
		layout_relations(positions, display, EventStructure, all_events(display))
	    end
	end

	class Distributed::MarshalledPlanObject
	    attr_reader :dot_id

	    # Adds the dot definition for this object in +io+
	    def to_dot(display, io)
		return unless display.displayed?(self)
		@dot_id = io.layout_id(self)
		io << "  #{dot_id}[label=\"#{display_name.split("\n").join('\n')}\"];\n"
	    end

	    # Applys the layout in +positions+ to this particular object
	    def apply_layout(positions, display)
		return unless display.displayed?(self)
		if p = positions[dot_id]
		    display[self].pos = p
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
	    def to_dot(display, io); end
	    def apply_layout(positions, display); end
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
	    def layout(display, plan, scale)
		# Dot input file
		@dot_input  = Tempfile.new("roby_dot")
		# Dot output file
		dot_output = Tempfile.new("roby_layout")

		dot_input << "digraph relations {\n" 
		#+
		#       "  nslimit=4.0;\n" +
		#       "  fslimit=4.0;\n"

		plan.to_dot(display, self, 0)
		dot_input << "\n};"
		dot_input.flush
		FileUtils.cp(dot_input.path, "/tmp/dot_layout.input.#{@@bkpindex += 1}")
		system("dot #{dot_input.path} > #{dot_output.path}")
		FileUtils.cp(dot_output.path, "/tmp/dot_layout.output.#{@@bkpindex}")

		xmin, ymin = 1024, 1024
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
			xmin = x if x < xmin
			ymin = y if y < ymin
			object_pos[$1] = Qt::PointF.new(x, y)
		    when /bb="(\d+),(\d+),(\d+),(\d+)"/
			bb = [$1, $2, $3, $4].map(&method(:Integer))
			if !graph_bb
			    graph_bb = bb
			end
		    end
		    full_line = ""
		end
		return unless graph_bb

		object_pos.each do |id, pos|
		    pos.x -= xmin
		    pos.y -= ymin
		end
		plan.apply_layout(object_pos, display)

	    ensure
		dot_input.close!  if dot_input
		dot_output.close! if dot_output
	    end
	end
    end
end
