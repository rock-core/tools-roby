require 'utilrb/enumerable'
require 'utilrb/value_set'
require 'roby/bgl'

Utilrb.unless_faster do
    raise LoadError, "Roby needs Utilrb's C extension to be compiled"
end

module BGL
    module Vertex
	def clear_vertex
	    each_graph { |g| g.remove(self) }
	end
	def component(graph)
	    graph.components(self).first
	end
	def directed_component(graph)
	    graph.directed_components(self).first
	end
	def reverse_directed_component(graph)
	    graph.reverse_directed_components(self).first
	end

	def replace_vertex_by(to)
	    each_graph { |g| g.replace_vertex(self, to) }
	end
    end
    class Graph
	def replace_vertex(from, to)
	    from.each_parent_vertex(self) do |parent|
		link(parent, to, parent[from, self])
	    end
	    from.each_child_vertex(self) do |child|
		link(to, child, from[child, self])
	    end
	    remove(from)
	end
    end
end

