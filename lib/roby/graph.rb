require 'utilrb/enumerable'
require 'utilrb/value_set'
require 'roby/bgl'

Utilrb.unless_faster do
    raise LoadError, "Roby needs Utilrb's C extension to be compiled"
end

module BGL
    module Vertex
	def initialize_copy(v)
	    super

	    @__bgl_graphs__ = nil
	    v.each_graph(&g.method(:insert))
	end

	def clear_vertex
	    each_graph { |g| g.remove(self) }
	end
	def component(graph)
	    graph.components(self).first
	end
	def generated_subgraph(graph)
	    graph.generated_subgraphs(self).first
	end
	def reverse_generated_subgraph(graph)
	    graph.reverse.generated_subgraphs(self).first
	end

	def replace_vertex_by(to)
	    each_graph { |g| g.replace_vertex(self, to) }
	end

	def neighborhood(distance, graph = nil)
	    if graph
		graph.neighborhood(self, distance).
		    map! { |*args| args << graph }
	    else
		edges = []
		each_graph do |graph|
		    edges += neighborhood(distance, graph)
		end
		edges
	    end
	end
    end

    class Graph
	class Reverse
	    def initialize(g)
		@__bgl_real_graph__ = g
	    end
	end
	attribute(:reverse)    { @reverse = Graph::Reverse.new(self) }

	class Undirected
	    def initialize(g)
		@__bgl_real_graph__ = g
	    end
	end
	attribute(:undirected) { @undirected = Graph::Undirected.new(self) }

	def initialize_copy(source)
	    super

	    source.each_vertex { |v| insert(v) }
	    source.each_edge { |s, t, i| link(s, t, i) }
	end

	def replace_vertex(from, to)
	    from.each_parent_vertex(self) do |parent|
		link(parent, to, parent[from, self])
	    end
	    from.each_child_vertex(self) do |child|
		link(to, child, from[child, self])
	    end
	    remove(from)
	end

	def neighborhood(vertex, distance)
	    seen   = Set.new
	    result = []
	    each_bfs(vertex, TREE) do |from, to, info, _|
		unless seen.include?(from)
		    break if distance == 0
		    distance -= 1
		    seen.insert(from)
		end
		result << [from, to, info]
	    end
	    result
	end

	# Two graphs are the same if they have the same vertex set
	# and the same edge set
	def ==(other)
	    # cannot use to_value_set for edges since we are comparing arrays (and ValueSet
	    # bases its comparison on VALUE)
	    (other.enum_for(:each_vertex).to_value_set == enum_for(:each_vertex).to_value_set) && 
		(other.enum_for(:each_edge).to_set == enum_for(:each_edge).to_set)
	end
    end
end

