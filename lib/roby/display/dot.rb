require 'roby/support'
require 'roby/event'
require 'graphviz'
require 'set'

module Roby
    module Display
        class Dot
            attr_reader :graph
            attr_reader :task_graphs, :event_nodes
            attr_reader :relations

            def initialize(graph = nil)
                @graph = if graph.respond_to?(:to_str)
                             GraphViz.new(graph)
                         elsif !graph
                             GraphViz.new('')
                         else
                             graph
                         end

                @graph["compound"] = "true"
                @graph["fontsize"] = "8"
                @graph.edge["lhead"] = ""
                @graph.edge["ltail"] = ""
                @graph.node["color"] = "black"
                @graph.node["fontsize"] = "8"
                @graph.node["height"] = "0"
                @graph.node["width"] = "0"

    
                @task_graphs = Hash.new
                @event_nodes = Hash.new
                @relations   = Hash.new { |h, k| h[k] = Set.new }
            end

            def task(task)
                return task_graphs[task] if task_graphs[task]
                
                task_label  = task.class.name.gsub('Roby::', '')
                graph_id    = "cluster_#{task_label.gsub('::', '_')}"
                task_graph = graph.add_graph(graph_id)
                class << task_graph; attr_accessor :name end
                task_graph.name     = graph_id
                task_graphs[task]   = task_graph
                task_graph["label"] = task_label
                task_graph["style"] = "filled"
                task_graph["color"] = "lightgrey"
		task_graph["rankdir"] = 'LTR'
                task.each_event(false) { |ev| event(ev) }

                return task_graph
            end

            EVENT_GENERATOR_NAMES = { 
                OrGenerator => '|', 
                AndGenerator => '&',
                EverGenerator => 'ever',
		ForwarderGenerator => '=>',
		EventGenerator => '!'
            }
                
            def event(event)
                return event_nodes[event] if event_nodes[event]

                if event.respond_to?(:task)
                    cluster = task(event.task)
                    name    = event.symbol.to_s
                    id      = "#{cluster.name.gsub(/^cluster_/, '')}_#{name}"
                else
                    cluster = self.graph
                    name    = EVENT_GENERATOR_NAMES[event.class] || event.class.name
                    id      = "#{event.class.name.gsub(/::/, '_')}_#{event.object_id.abs.to_s(16)}"
                end

                node = cluster.add_node(id, "label" => name.to_str)
                if event.respond_to?(:task)
                    if [:start, :stop].include?(event.symbol)
                        node["style"] = "filled"
                    end
                    if :start == event.symbol
                        node["color"] = "green"
                    elsif event.terminal?
                        node["color"] = "red"
                    end
                end

                event_nodes[event] = node
            end

            def task_relation(kind, task, style = Hash.new)
                return if relations[kind].include?(task)
                relations[kind] << task
                self.task(task)

		root = task.enum_leafs(:each_parent_object, kind).to_a
		def root.each_child_object(kind, &iterator)
		    each(&iterator)
		end

                root.enum_dfs(:each_child_object, kind).each_edge do |parent, child|
		    next if parent == root
                    next if relations[kind].include? [parent, child]
                    relations[kind] << [parent, child]

                    child_event  = event(child.event(:start))
		    parent_event = event(parent.event(:start)) 
		    edge_style   = style.merge "lhead" => task(child).name, "ltail" => task(parent).name
		    graph.add_edge( parent_event, child_event, edge_style )
                end
            end
            def event_relation(kind, event, style = Hash.new)
                return if relations[kind].include?(event)
                relations[kind] << event

		root = event.enum_leafs(:each_parent_object, kind).to_a
		def root.each_child_object(kind, &iterator)
		    each(&iterator)
		end

		root.enum_dfs(:each_child_object, kind).each_edge do |parent, child|
		    next if parent == root
                    next if relations[kind].include?  [parent, child]
                    relations[kind] << [parent, child]
                    graph.add_edge( event(parent), event(child), style.merge("constraint" => "false") )
                end
            end

            def display
                #@graph.output "output" => "dot"
                Tempfile.open("roby-dot") do |file|
                    @graph.output "file" => file.path, "output" => "png"

                    require 'RMagick'
                    Magick::Image.read(file.path).first.display
                end
            end
        end
    end
end

