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
            # from the 'source's parents vertices to 'target'. As well as adding edges
            # from the from 'source' to 'target's children vertices 
            #
            # @param source [Object] The source vertex
            # @param target [Object] The target vertex
            def added_edge(source, target)
                return if @graph.has_edge?(source, target)

                @graph.add_edge(source, target)
                add_edges_to_parents(source, target)
                add_edges_to_children(source, target)
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

            # Updates the transitive closure by adding edges from the 'source's parents 
            # vertices to 'target', thus ensuring that the graph's 
            # reachability is consistent.
            #
            # @param source [Object] The source vertex
            # @param target [Object] The target vertex
            def add_edges_to_parents(source, target)
                parents = parent_vertices(source)
                parents.each do |parent|
                    @graph.add_edge(parent, target) unless @graph.has_edge?(parent, target)
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

            # Updates the transitive closure by adding edges from 'source' to
            # the 'target's children vertices, thus ensuring that the graph's 
            # reachability is consistent.
            #
            # @param source [Object] The source vertex
            # @param target [Object] The target vertex
            def add_edges_to_children(source, target)
                children = @graph.adjacent_vertices(target)
                children.each do |child|
                    @graph.add_edge(source, child) unless @graph.has_edge?(source, child)
                end
            end
        end
    end
end
