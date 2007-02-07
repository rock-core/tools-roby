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

module Roby::Display
    Marshallable = Roby::Marshallable

    class DotLayout
	# A name => object map of clusters
	attr_reader :task_clusters
	# The input file for dot
	attr_reader :dot
	# The display object
	attr_reader :display
	# The level of nesting for each plan
	attr_reader :plan_levels

	def initialize
	    @task_clusters = Hash.new
	    @plan_level = 1
	    @plan_levels = Hash.new
	end

	def dot_id(object)
	    Object.address_from_id(object.source_id).to_s
	end

	def plan(id, objects)
	    dot << "subgraph cluster_plan_#{id} {\n"
		plan_levels[id] = @plan_level
		@plan_level += 1
		objects.each { |o| o.dot(self) }
		@plan_level -= 1
	    dot << "};\n"
	end

	def task(task)
	    return if display.hidden?(task)
	    task_id = dot_id(task)
	    dot << "  #{task_id}[label=\"#{task.name}\"];\n"
	end


	def self.layout(display, scale)
	    DotLayout.new.layout(display, scale)
	end
	def layout(display, scale)
	    @display = display

	    # Dot input file
	    @dot = Tempfile.new("roby_dot")
	    # Dot output file
	    dot_layout = Tempfile.new("roby_layout")

	    dot << "digraph relations {\n" +
		   "  nslimit=4.0;\n" +
		   "  fslimit=4.0;\n"

	    # Events that are not task events
	    display.each_event(nil) do |ev|
		dot << "#{dot_id(ev)}[label=#{ev.source_id}];\n"
	    end

	    plan_levels.clear
	    display.each_plan(&method(:plan))
	    plan_levels[0] = 0

	    display.each_task_relation do |kind, from, to|
		next if display.hidden?(from) || display.hidden?(to)

		# Find one event in each task to define an edge between the tasks
		from = dot_id(from)
		to   = dot_id(to)
		dot << "#{from} -> #{to};\n"
	    end
	    display.each_event_relation do |kind, from, to|
		next if display.hidden?(from) || display.hidden?(to)
		from = from.task if from.respond_to?(:task)
		to   = to.task if to.respond_to?(:task)
		dot << "#{dot_id(from)} -> #{dot_id(to)};\n"
	    end
	    dot << "};\n"

	    dot.flush
	    FileUtils.cp(dot.path, "/tmp/dot_layout.bkp")
	    system("dot #{dot.path} > #{dot_layout.path}")

	    graph_bb = nil
	    tasks_bb = Hash.new

	    # Load only task bounding boxes from dot, update arrows later
	    graph_size = nil
	    task_pos = Hash.new
	    lines = File.open(dot_layout.path) { |io| io.readlines  }
	    lines.each do |line|
		case line
		when /(\d+) \[.*pos="(\d+),(\d+)"/
		    task_pos[$1] = [Integer($2), Integer($3)]
		when /bb="(\d+),(\d+),(\d+),(\d+)"/
		    bb = [$1, $2, $3, $4].map(&method(:Integer))
		    if !graph_bb
			graph_bb = bb
		    end
		end
	    end
	    return unless graph_bb

	    # Resize the canvas if needed
	    graph_size  = [graph_bb[2] * scale, graph_bb[3] * scale]
	    canvas_size = [display.canvas.width, display.canvas.height]
	    needed_size = canvas_size.zip(graph_size).map { |s| s.max }
	    if needed_size != canvas_size
		display.canvas.resize(*needed_size)
	    end

	    max_level = plan_levels.values.max
	    plan_levels[nil] = 0

	    display.each_plan(true) do |id, tasks|
		next if tasks.empty?
		plan_bb = [display.canvas.width, display.canvas.height, 0, 0]
		tasks.each do |t|
		    if pos = task_pos[dot_id(t)]
			pos.map! { |i| i *= scale }
		    else
			STDERR.puts "WARNING: ignoring #{t.name}:#{dot_id(t)}"
			next
		    end

		    element = display.canvas_task(t)
		    element.move(pos[0], graph_size[1] - pos[1])

		    plan_bb[0] = [plan_bb[0], element.x - element.width / 3].min
		    plan_bb[1] = [plan_bb[1], element.y - element.height / 3].min
		    plan_bb[2] = [plan_bb[2], element.x + element.width * 4 / 3].max
		    plan_bb[3] = [plan_bb[3], element.y + element.height].max
		end
		display.canvas_plan(max_level + 1, plan_levels[id], *plan_bb)
	    end

	    display.each_task_relation  { |kind, from, to| display.canvas_arrow(kind, from, to) }
	    display.each_event_relation { |kind, from, to| display.canvas_arrow(kind, from, to) }
	    display.canvas.update

	ensure
	    dot.close! if dot
	    dot_layout.close! if dot_layout
	end
    end
end

