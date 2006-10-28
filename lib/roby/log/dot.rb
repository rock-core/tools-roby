require 'tempfile'
module Roby::Display
    Marshallable = Roby::Marshallable

    class DotLayout
	def self.dot_name(object)
	    id = Object.address_from_id(object.source_id).to_s
	    case object
	    when Marshallable::Task
		"cluster_#{id}"
	    else
		id
	    end
	end

	def self.layout(display, scale)
	    # Write dot file
	    dot = Tempfile.new("roby_dot")
	    dot_layout = Tempfile.new("roby_layout")

	    dot << "digraph relations {\n"

	    # Events that are not task events
	    display.each_event(nil) do |ev|
		dot << "#{dot_name(ev)}[label=#{ev.source_id}];\n"
	    end

	    # Clusters is a task_cluster_name => [task, reference_node] hash
	    clusters = Hash.new
	    display.each_task do |task|
		next if display.hidden?(task)
		task_dot_name = dot_name(task)
		clusters[task_dot_name] = [task]

		dot << "subgraph #{task_dot_name} {\n"
		has_event = false
		display.each_event(task) do |ev|
		    next if display.hidden?(ev)

		    dot << "#{dot_name(ev)}[label=#{ev.symbol}];\n"
		    if !has_event
			has_event = true
			clusters[task_dot_name] << dot_name(ev)
		    end
		    has_event = true
		end
		if !has_event
		    blind_event = task_dot_name.gsub('cluster_', '')
		    dot << "#{blind_event};"
		    clusters[task_dot_name] << blind_event
		end
		dot << "};\n"
	    end

	    display.each_task_relation do |kind, from, to|
		next if display.hidden?(from) || display.hidden?(to)

		# Find one event in each task to define an edge between the tasks
		from = clusters[dot_name(from)].last
		to   = clusters[dot_name(to)].last
		dot << "#{from} -> #{to};\n"
	    end
	    display.each_event_relation do |kind, from, to|
		next if display.hidden?(from) || display.hidden?(to)
		dot << "#{dot_name(from)} -> #{dot_name(to)};\n"
	    end
	    dot << "};\n"

	    dot.flush
	    system("dot #{dot.path} > #{dot_layout.path}") 

	    # Load only task bounding boxes from dot, update arrows later
	    task, graph_size = nil
	    lines = File.open(dot_layout.path) { |io| io.readlines  }
	    lines.each do |line|
		if line =~ /subgraph (cluster_\w+) \{/
		    task = clusters[$1].first
		elsif line =~ /graph \[bb="(\d+),(\d+),(\d+),(\d+)"\]/
		    bb = [$1, $2, $3, $4].map { |i| Integer(i) }
		    if !task
			graph_size = [bb[2] * scale, bb[3] * scale]
			canvas = display.canvas
			sizes = [canvas.width, canvas.height].zip(graph_size)

			if sizes.find { |d, c| d > c }
			    new_size = sizes.map { |s| s.max }
			    canvas.resize(*new_size)
			end
		    else
			pos = [(bb[0] + bb[2]) / 2, 
			       (bb[1] + bb[3]) / 2].map { |i| i *= scale }
			

			element = display.canvas_task(task)
			element.move(pos[0], graph_size[1] - pos[1])
		    end
		end
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

