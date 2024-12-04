# frozen_string_literal: true

require 'rgl/adjacency'
require 'rgl/transitivity'

module Roby
    module Relations
        class IncrementalTransitiveClosure
            attr_reader :graph

            def initialize
                @graph = RGL::DirectedAdjacencyGraph.new
            end
        
            def added_vertex(vertex)
                return if @graph.has_vertex?(vertex)
                @graph.add_vertex(vertex)
            end
            
            def added_edge(from, to)
                @graph.add_edge(from, to)
                add_edges_to_parents(from, to)
            end

            def removed_vertex(vertex)
                if @graph.adjacent_vertices(vertex).empty?
                    @graph.remove_vertex(vertex)
                else
                    @graph = RGL::DirectedAdjacencyGraph.new
                end
            end

            def removed_edge(from, to)
                if @graph.adjacent_vertices(to).empty?
                    @graph.remove_edge(from, to)
                else
                    @graph = RGL::DirectedAdjacencyGraph.new
                end
            end
            
            def reachable?(from, to)
                @graph.has_edge?(from, to)
            end

            def add_edges_to_parents(from, to)
                parents = @graph.edges.select { |edge| edge.target == from }.map(&:source)
                parents.each do |parent|
                    @graph.add_edge(parent, to) unless @graph.has_edge?(parent, to)
                end
            end
        end
    end
end
