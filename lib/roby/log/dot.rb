require 'tempfile'
module Roby::Display
    class DotLayout
	def self.dot_name(object)
	    Object.address_from_id(object.source_id).to_s
	end

	def self.layout(display, scale)
	    clusters = Hash.new

	    # Write dot file
	    dot		= Tempfile.new("roby_dot")
	    dot_layout  = Tempfile.new("roby_layout")

	    dot << "strict digraph event_structure {\n"

	    display.each_event(nil) do |ev|
		dot << "#{dot_name(ev)}[label=#{ev.symbol}];\n"
	    end

	    display.each_task do |task|
		task_dot_name = dot_name(task)
		clusters[task_dot_name] = task
		dot << "subgraph cluster_#{task_dot_name} {\n"
		display.each_event(task) do |ev|
		    dot << "#{dot_name(ev)}[label=#{ev.symbol}];\n"
		end
		dot << "};\n"
	    end

	    display.each_relation do |from, to|
		dot << "#{dot_name(from)} -> #{dot_name(to)};\n"
	    end
	    dot << "};\n"

	    dot.flush
	    system("dot #{dot.path} > #{dot_layout.path}") 

	    # Load only task bounding boxes from dot, update arrows later
	    task, graph_size = nil
	    lines = File.open(dot_layout.path) { |io| io.readlines  }
	    lines.each do |line|
		if line =~ /subgraph cluster_(\w+) \{/
		    task = clusters[$1]
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

	    display.each_relation { |from, to| display.canvas_arrow(from, to) }
	    display.canvas.update
	end
    end
end

