# frozen_string_literal: true

require 'rgl/adjacency'
require 'rgl/transitivity'

module Roby
    module Relations
        # This class represents an incremental transitive closure graph, 
        # where edges and vertices can be added or removed incrementally, 
        # while keeping track of reachability information (i.e., transitive closure).
        class IncrementalTransitiveClosure
            attr_reader :graph

            # Initializes an empty directed graph using RGL's DirectedAdjacencyGraph
            def initialize
                @graph = RGL::DirectedAdjacencyGraph.new
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

                parents = parent_vertices(source)
                add_edges_vertices_to_vertex(parents, target)

                children = @graph.adjacent_vertices(target)
                add_edges_vertex_to_vertices(source, children)

                add_edges_vertices_to_vertices(parents, children)
            end

            # Removes a vertex from the graph if it has no adjacent vertices 
            # (i.e., no outgoing edges)
            # If there are adjacent vertices, the entire graph is 
            # reset (rebuilds the graph)
            #
            # @param vertex [Object] The vertex to be removed
            def removed_vertex(vertex)
                return unless @graph.has_vertex?(vertex)

                if @graph.adjacent_vertices(vertex).empty?
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

                if @graph.adjacent_vertices(target).empty? && parent_vertices(source).empty?
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

            # Updates the transitive closure by adding edges from source vertices to a target 
            # vertex
            #
            # @param target [Object] The target vertex
            # @param vertices [Array<Object>] An array of source vertices
            def add_edges_vertices_to_vertex(vertices, target)
                vertices.each do |vertex|
                    @graph.add_edge(vertex, target) unless @graph.has_edge?(vertex, target)
                end
            end

            # Return the parent vertices of the provided vertex
            #
            # @param from [Object] The source vertex
            #
            # @return [Array<Object>] An array of parent vertices (those that point to 
            # the given vertex).
            def parent_vertices(vertex)
                return @graph.edges.select { |edge| edge.target == vertex }.map(&:source)
            end

            # Updates the transitive closure by adding edges from a source vertex to 
            # target vertices
            #
            # @param source [Object] The source vertex
            # @param vertices [Array<Object>] An array of target vertices
            def add_edges_vertex_to_vertices(source, vertices)
                vertices.each do |vertex|
                    @graph.add_edge(source, vertex) unless @graph.has_edge?(source, vertex)
                end
            end

            # Updates the transitive closure by adding edges from source vertices to target 
            # vertices
            #
            # @param source_vertices [Array<Object>] An array of source vertices
            # @param target_vertices [Array<Object>] An array of target vertices
            def add_edges_vertices_to_vertices(source_vertices, target_vertices)
                source_vertices.each do |source|
                    target_vertices.each do |target|
                        @graph.add_edge(source, target) unless @graph.has_edge?(source, target)
                    end
                end
            end
        end
    end
end
