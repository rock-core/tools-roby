# frozen_string_literal: true

require "roby"
require "benchmark"

require "ruby-prof"

class Graph < Roby::Relations::Graph
end

class Vertex
    include Roby::Relations::DirectedRelationSupport

    attr_reader :relation_graphs

    def initialize(graph)
        @relation_graphs = Hash[graph => graph, graph.class => graph]
    end
end

COUNT = 10_000
Benchmark.bm(80) do |x|
    graph = Graph.new
    vertices = (1..COUNT).map { Vertex.new(graph) }
    x.report("add #{COUNT} vertices") do
        vertices.each { |o| graph.add_vertex(o) }
    end
    x.report("remove #{COUNT} vertices") do
        vertices.each { |o| graph.remove_vertex(o) }
    end

    graph = Graph.new
    vertices = (1..2 * COUNT).map { Vertex.new(graph) }
    vertices.each { |o| graph.add_vertex(o) }
    x.report("#{COUNT} separate links between already inserted vertices") do
        vertices.each_slice(2) { |parent, child| graph.add_relation(parent, child, nil) }
    end
    x.report("unlink #{COUNT} separate links") do
        vertices.each_slice(2) { |parent, child| graph.remove_relation(parent, child) }
    end

    graph = Graph.new
    vertices = (1..2 * COUNT).map { Vertex.new(graph) }
    x.report("#{COUNT} separate links, inserted vertices") do
        vertices.each_slice(2) { |parent, child| graph.add_relation(parent, child, nil) }
    end

    graph = Graph.new
    graph.add_vertex(shared_v = Vertex.new(graph))
    vertices = (1..COUNT).map { Vertex.new(graph) }
    vertices.each { |o| graph.add_vertex(o) }
    x.report("#{COUNT} links with a shared vertex between already inserted vertices") do
        vertices.each { |o| graph.add_relation(shared_v, o, nil) }
    end

    graph = Graph.new
    shared_v = Vertex.new(graph)
    vertices = (1..COUNT).map { Vertex.new(graph) }
    x.report("#{COUNT} links with a shared vertex, "\
             "inserting vertices at the same time") do
        vertices.each { |o| graph.add_relation(shared_v, o, nil) }
    end
end
