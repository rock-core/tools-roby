# frozen_string_literal: true

require "roby/relations/bidirectional_directed_adjacency_graph"
require "rgl/traversal"

module Roby
    module Relations
        # Class of visitor used for dfs a graph, in case a vertex is already present in
        # the transitive closure, the path is ignored.
        #
        # This should be used the the IncrementalTransitiveClosure#discover_vertex to fill
        # unpopulated paths, ignoring those already seen.
        class IncrementalTransitiveClosureVisitor < RGL::DFSVisitor
            def initialize(graph, transitive_closure)
                super(graph)
                @g = graph
                @tc = transitive_closure
            end

            def follow_edge?(source, target)
                if @tc.graph.has_vertex?(target)
                    @tc.added_edge(source, target)
                    false
                else
                    @tc.added_vertex(target)
                    @tc.added_edge(source, target)
                    super(source, target)
                end
            end
        end

        # This class represents an incremental transitive closure graph,
        # where edges and vertices can be added or removed incrementally,
        # while keeping track of reachability information (i.e., transitive closure).
        class IncrementalTransitiveClosure
            attr_reader :graph

            # Initializes an empty directed graph using
            # BidirectionalDirectedAdjacencyGraph
            def initialize
                @graph =
                    Relations::BidirectionalDirectedAdjacencyGraph.new
            end

            # Adds a new vertex to the graph if it doesn't already exist
            #
            # @param vertex [Object] The vertex to be added
            def added_vertex(vertex)
                return if @graph.has_vertex?(vertex)

                @graph.add_vertex(vertex)
            end

            # Adds an edge from 'source' to 'target' to the graph
            # It also ensures that transitive reachability is updated by adding edges
            # from the 'source's parents vertices to 'target'. Adding edges
            # from the from 'source' to 'target's children vertices.
            # As well as adding edges from 'source's parent vertices to 'target's children
            #
            # @param source [Object] The source vertex
            # @param target [Object] The target vertex
            def added_edge(source, target)
                return if @graph.has_edge?(source, target) ||
                          source == target

                @graph.add_edge(source, target)

                @graph.propagate_transitive_closure(source, target)
            end

            # Removes a vertex from the graph if it has no adjacent vertices
            # (i.e., no outgoing edges)
            # If there are adjacent vertices, the entire graph is
            # reset (rebuilds the graph)
            #
            # @param vertex [Object] The vertex to be removed
            def removed_vertex(vertex)
                return unless @graph.has_vertex?(vertex)

                if @graph.leaf?(vertex)
                    @graph.remove_vertex(vertex)
                else
                    @graph =
                        Relations::BidirectionalDirectedAdjacencyGraph.new
                end
            end

            # Removes an edge from the graph. If the target vertex has adjacent vertices,
            # or the source vertex has parent vertices
            # the entire graph is reset. Otherwise, it simply removes the edge.
            #
            # @param source [Object] The source vertex
            # @param target [Object] The target vertex
            def removed_edge(source, target)
                return unless @graph.has_edge?(source, target)

                if @graph.leaf?(target) &&
                   @graph.root?(source)
                    @graph.remove_edge(source, target)
                else
                    @graph =
                        Relations::BidirectionalDirectedAdjacencyGraph.new
                end
            end

            # Checks if there is a directed edge from 'source' to 'target'
            # (i.e., if 'target' is reachable from 'source').
            #
            # If the incremental transitive closure already has this node discovered,
            # it will simply test if this edge exists. If not, it will execute a depth
            # first visit, exploring the nodes and their relations along the way.
            #
            # @param source [Object] The source vertex
            # @param target [Object] The target vertex
            # @param source_graph [Graph] The graph to check for the edge
            #
            # @return [Boolean] Returns true if there is a direct edge from 'source'
            # to 'target', false otherwise
            def reachable?(source, target, source_graph)
                discover_vertex(source, source_graph) unless @graph.has_vertex?(source)

                @graph.has_edge?(source, target)
            end

            # Discovers vertices reachable from 'source' and adds them to the
            # transitive closure. This method performs a DFS to explore the graph
            # incrementally.
            #
            # @param source [Object] The source vertex to start the DFS
            # @param graph [Graph] The graph to explore during the DFS
            def discover_vertex(source, source_graph)
                vis = IncrementalTransitiveClosureVisitor.new(source_graph, self)
                added_vertex(source)
                source_graph.depth_first_visit(source, vis) {}
            end
        end
    end
end
