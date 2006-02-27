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
                task.each_event(false) { |ev| event(ev) }

                return task_graph
            end

            EVENT_GENERATOR_NAMES = { 
                OrGenerator => '|', 
                AndGenerator => '&',
                EverGenerator => 'ever'
            }
                
            def event(event)
                return event_nodes[event] if event_nodes[event]

                if event.respond_to?(:task)
                    cluster = task(event.task)
                    name    = event.symbol.to_s
                    id      = "#{cluster.name.gsub(/^cluster_/, '')}_#{name}"
                else
                    cluster = self.graph
                    name    = EVENT_GENERATOR_NAMES[event.class]
                    id      = "#{name}_#{event.object_id}"
                end

                node = cluster.add_node(id, "label" => name)
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

            def task_relation(kind, task, enum_with, style = Hash.new)
                return if relations[kind].include?(task)
                relations[kind] << task
                self.task(task)

                task.enum_dfs(enum_with) do |child, parent|
                    next if relations.include?(child)
                    relations[kind] << child
                    self.task(child)

                    parent_event = event(parent.event(:start))
                    child_event  = event(child.event(:start))
                    edge_style = style.merge "lhead" => task(child).name, "ltail" => task(parent).name
                    graph.add_edge( parent_event, child_event, edge_style )
                end
            end
            def event_relation(kind, event, enum_with, style = Hash.new)
                return if relations[kind].include?(event)
                relations[kind] << event

                event.enum_dfs(enum_with) do |child, parent|
                    next if relations.include?(child)
                    relations[kind] << child
                    graph.add_edge( event(parent), event(child), style )
                end
            end

            def display
                #@graph.output "output" => "dot"
                Tempfile.open("roby-dot") do |file|
                    $stderr.puts "generating graph"
                    @graph.output "file" => file.path, "output" => "png"

                    $stderr.puts "displaying graph"
                    require 'RMagick'
                    Magick::Image.read(file.path).first.display
                end
            end
        end
    end
end

