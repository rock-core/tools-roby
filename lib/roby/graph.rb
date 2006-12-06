require 'utilrb/module'
require 'utilrb/kernel'
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

	def edges
	    result = []
	    each_graph do |graph|
		graph_edges = []
		each_child_object do |child|
		    graph_edges << [self, child, self[child, graph]]
		end
		each_parent_object do |parent|
		    graph_edges << [parent, self, parent[self, graph]]
		end
		result << [graph, graph_edges]
	    end

	    result
	end

	# call-seq:
	#   v.neighborhood(distance, graph) => [[graph, v, v1, data], [graph, v2, v, data], ...]
	#   v.neighborhood(distance)	    => [[g1, v, v1, data], [g2, v2, v, data], ...]
	#
	# Returns a list of [graph, edge] representing all edges at a maximum distance
	# of +distance+ from +self+. If +graph+ is given, only enumerate the neighborhood
	# in +graph+.
	def neighborhood(distance, graph = nil)
	    if graph
		graph.neighborhood(self, distance).
		    map! { |args| args.unshift(graph) }
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
	    result = []
	    seen = Set.new
	    depth = { vertex => 0 }
	    undirected.each_bfs(vertex, ALL) do |from, to, info, kind|
		new_depth = depth[from] + 1
		if kind == TREE
		    depth[to] = new_depth
		else
		    next if seen.include?(to)
		end
		seen << from

		if depth[from] > distance
		    break
		end

		if new_depth <= distance
		    if linked?(from, to)
			result << [from, to, info]
		    else
			result << [to, from, info]
		    end
		end
	    end
	    result
	end

	# Two graphs are the same if they have the same vertex set
	# and the same edge set
	def same_graph?(other)
	    unless other.respond_to?(:each_vertex) && other.respond_to?(:each_edge)
		return false
	    end

	    # cannot use to_value_set for edges since we are comparing arrays (and ValueSet
	    # bases its comparison on VALUE)
	    (other.enum_for(:each_vertex).to_value_set == enum_for(:each_vertex).to_value_set) && 
		(other.enum_for(:each_edge).to_set == enum_for(:each_edge).to_set)
	end
    end
end

