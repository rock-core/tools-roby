# frozen_string_literal: true

require 'roby/relations/bidirectional_directed_adjacency_graph'

module Roby
    module Relations
        # This class represents an incremental transitive closure graph, 
        # where edges and vertices can be added or removed incrementally, 
        # while keeping track of reachability information (i.e., transitive closure).
        class IncrementalTransitiveClosure
            attr_reader :graph

            # Initializes an empty directed graph using BidirectionalDirectedAdjacencyGraph
            def initialize
                @graph = Relations::BidirectionalDirectedAdjacencyGraph.new
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
                return if @graph.has_edge?(source, target)

                @graph.add_edge(source, target)

                @graph.each_out_neighbour(target) do |out_neighbor|
                    @graph.add_edge(source, out_neighbor)
                end
                                
                @graph.each_in_neighbour(source) do |in_neighbor|
                    @graph.add_edge(in_neighbor, target)
                end

                @graph.each_out_neighbour(target) do |out_neighbor|
                    @graph.each_in_neighbour(source) do |in_neighbor|
                        @graph.add_edge(in_neighbor, out_neighbor)
                    end
                end
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
                    @graph = RGL::DirectedAdjacencyGraph.new
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

                if @graph.leaf?(target) && @graph.root?(source)
                    @graph.remove_edge(source, target)
                else
                    @graph = RGL::DirectedAdjacencyGraph.new
                end
            end
            
            # Checks if there is a directed edge from 'source' to 'target' 
            # (i.e., if 'target' is reachable from 'source')
            #
            # @param source [Object] The source vertex
            # @param target [Object] The target vertex
            #
            # @return [Boolean] Returns true if there is a direct edge from 'source' 
            # to 'target', false otherwise
            def reachable?(source, target)
                @graph.has_edge?(source, target)
            end
        end
    end
end
