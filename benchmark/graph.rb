require 'roby'
require 'benchmark'

require 'ruby-prof'

COUNT = 10_000
Benchmark.bm(80) do |x|
    tasks = Array.new

    graph = BGL::Graph.new
    vertices = (1..COUNT).map { Object.new }
    x.report("insert #{COUNT} vertices") do
        vertices.each { |o| graph.insert(o) }
    end
    x.report("remove #{COUNT} vertices") do
        vertices.each { |o| graph.remove(o) }
    end

    graph = BGL::Graph.new
    vertices = (1..2*COUNT).map { Object.new }
    vertices.each { |o| graph.insert(o) }
    x.report("#{COUNT} separate links between already inserted vertices") do
        vertices.each_slice(2) { |parent, child| graph.link(parent, child, nil) }
    end
    x.report("unlink #{COUNT} separate links") do
        vertices.each_slice(2) { |parent, child| graph.unlink(parent, child) }
    end

    graph = BGL::Graph.new
    vertices = (1..2*COUNT).map { Object.new }
    x.report("#{COUNT} separate links, inserted vertices") do
        vertices.each_slice(2) { |parent, child| graph.link(parent, child, nil) }
    end

    graph = BGL::Graph.new
    graph.insert(shared_v = Object.new)
    vertices = (1..COUNT).map { Object.new }
    vertices.each { |o| graph.insert(o) }
    x.report("#{COUNT} links with a shared vertex between already inserted vertices") do
        vertices.each { |o| graph.link(shared_v, o, nil) }
    end

    graph = BGL::Graph.new
    shared_v = Object.new
    vertices = (1..COUNT).map { Object.new }
    x.report("#{COUNT} links with a shared vertex, inserting vertices at the same time") do
        vertices.each { |o| graph.link(shared_v, o, nil) }
    end
end


