module Roby
    module Relations
        # Subclass of Relations::Space for events. Its main usage is to keep track of
        # which tasks are related in a given relation through their events.
        #
        # I.e. if events 'a' and 'b' are parts of the tasks ta and tb, and 
        #
        #   a -> b
        #
        # in this relation graph, then 
        #
        #   relation.related_tasks?(ta, tb)
        #
        # will return true
        class EventRelationGraph < Relations::Graph
            # The graph of tasks related to each other by their events
            attr_reader :task_graph

            def initialize(*args)
                super
                @task_graph = BidirectionalDirectedAdjacencyGraph.new
            end

            def add_edge(from, to, info)
                super

                if from.respond_to?(:task) && to.respond_to?(:task)
                    from_task, to_task = from.task, to.task
                    if from_task != to_task && !task_graph.has_edge?(from_task, to_task)
                        task_graph.add_edge(from_task, to_task, nil)
                    end
                end
            end

            def merge(graph)
                super
                task_graph.merge(graph.task_graph)
            end

            def replace(graph)
                super
                task_graph.replace(graph.task_graph)
            end

            def remove_vertex(event)
                super
                if event.respond_to?(:task)
                    task_graph.remove_vertex(event.task)
                end
            end

            def remove_edge(from, to)
                super

                if from.respond_to?(:task) && to.respond_to?(:task)
                    task_graph.remove_edge(from.task, to.task)
                end
            end

            def related_tasks?(ta, tb)
                task_graph.has_edge?(ta, tb)
            end

            def clear
                task_graph.clear
            end
        end
    end
end

