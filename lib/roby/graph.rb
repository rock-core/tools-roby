Utilrb.unless_ext do
    raise LoadError, "Roby needs Utilrb's C extension to be compiled"
end

module BGL
    module Vertex
        def initialize(*args, &block)
            super
	    @__bgl_graphs__ = nil
        end

	def initialize_copy(old)
	    super
	    @__bgl_graphs__ = nil
	end

	# Removes +self+ from all the graphs it is included in.
	def clear_vertex
            each_graph do |rel|
                rel.remove(self)
            end
	end

	attribute(:singleton_set) { [self].to_value_set.freeze }
	# Returns the connected component +self+ is part of in +graph+
	def component(graph)
	    graph.components(singleton_set, false).first || singleton_set
	end
	# Returns the vertex set which are reachable from +self+ in +graph+
	def generated_subgraph(graph)
	    graph.generated_subgraphs(singleton_set, false).first || singleton_set
	end
	# Returns the vertex set which can reach +self+ in +graph+
	def reverse_generated_subgraph(graph)
	    graph.reverse.generated_subgraphs(singleton_set, false).first || singleton_set
	end

	# Replace this vertex by +to+ in all graphs. See Graph#replace_vertex.
	def replace_vertex_by(to)
	    each_graph { |g| g.replace_vertex(self, to) }
	end

	# Returns an array of [graph, [parent, child, info], [parent, child,
	# info], ...] elements for all edges +self+ is involved in
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
	#   neighborhood(distance, graph) => [[graph, v, v1, data], [graph, v2, v, data], ...]
	#   neighborhood(distance)	    => [[g1, v, v1, data], [g2, v2, v, data], ...]
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
	# This class is an adaptor which transforms a directed graph by
	# swapping its edges
	class Reverse
	    # Create a directed graph whose edges are the ones of +g+, but with
	    # source and destination swapped.
	    def initialize(g)
		@__bgl_real_graph__ = g
	    end
	end
	attribute(:reverse)    { @reverse = Graph::Reverse.new(self) }

	# This class is a graph adaptor which transforms a directed graph into
	# an undirected graph
	class Undirected
	    # Create an undirected graph which has the same edge set than +g+
	    def initialize(g)
		@__bgl_real_graph__ = g
	    end
	end
	attribute(:undirected) { @undirected = Graph::Undirected.new(self) }

	def initialize_copy(source) # :nodoc:
	    super

	    source.each_vertex { |v| insert(v) }
	    source.each_edge { |s, t, i| link(s, t, i) }
	end

	# Replaces +from+ by +to+. This means +to+ takes the role of +from+ in
	# all edges +from+ is involved in. +from+ is removed from the graph.
	def replace_vertex(from, to)
	    from.each_parent_vertex(self) do |parent|
		link(parent, to, parent[from, self])
	    end
	    from.each_child_vertex(self) do |child|
		link(to, child, from[child, self])
	    end
	    remove(from)
	end

	# Returns a list of [parent, child, info] for all edges that are at a
	# distance no more than +distance+ from +vertex+.
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

        # Returns a set of removed edges and a set of new edges between elements
        # of +vertices+ in +self+ and +other_graph+.
        #
        # If a block is given, +vertices+ are vertices in +graph+ and this block
        # is used to translate them into vertices in +other_graph+. Otherwise,
        # we assume that both graphs include the same vertices. +other_graph+
        # can only be +self+ itself in the first case, and if the set of
        # vertices in +self+ have no intersection with the set of vertices in
        # +other_graph+)
        #
        # The method returns [new, removed, updated], where +new+ is the set of
        # edges that are in +self+ and not in +other_graph+, +removed+ the set
        # of edges that are in +other_graph+ but not in +self+ and +updated+ the
        # set of edges for which the +info+ parameter changed between the two
        # graphs.
        #
        # Each set is a Set of pairs
        #  
        #   [source_vertex, sink_vertex]
        #
        # The vertices are vertices of +self+ for +new+ and +updated+, and
        # vertices of +other_graph+ for +removed+
        def difference(other_graph, self_vertices)
            mapping =
                if block_given?
                    self_vertices.inject(Hash.new) do |h, v|
                        h[v] = yield(v)
                        h
                    end
                else lambda { |v| v }
                end
            other_vertices = ValueSet.new

            new, removed, updated = Set.new, Set.new, Set.new

            seen_vertices    = ValueSet.new
            seen_connections = Set.new
            for self_v in self_vertices
                other_v = mapping[self_v]
                other_vertices << other_v

                self_v.each_parent_vertex(self) do |self_parent|
                    # If we already worked on +self_parent+, this connection has
                    # already been taken into account
                    next if seen_vertices.include?(self_parent)

                    other_parent = mapping[self_parent]
                    if other_graph.linked?(other_parent, other_v)
                        if other_parent[other_v, other_graph] != self_parent[self_v, self]
                            updated << [self_parent, self_v]
                        end
                        seen_connections << [other_parent, other_v]
                    else
                        new << [self_parent, self_v]
                    end
                end

                self_v.each_child_vertex(self) do |self_child|
                    # If we already worked on +self_child+, this connection has
                    # already been taken into account
                    next if seen_vertices.include?(self_child)

                    other_child = mapping[self_child]
                    if other_graph.linked?(other_v, other_child)
                        if other_v[other_child, other_graph] != self_v[self_child, self]
                            updated << [self_v, self_child]
                        end
                        seen_connections << [other_v, other_child]
                    else
                        new << [self_v, self_child]
                    end
                end

                seen_vertices << self_v
            end

            seen_vertices.clear
            for other_v in other_vertices
                other_v.each_parent_vertex(other_graph) do |other_parent|
                    next if seen_vertices.include?(other_parent)
                    pair = [other_parent, other_v]
                    if !seen_connections.include?(pair)
                        removed << pair
                    end
                end
                other_v.each_child_vertex(other_graph) do |other_child|
                    next if seen_vertices.include?(other_child)
                    pair = [other_v, other_child]
                    if !seen_connections.include?(pair)
                        removed << pair
                    end
                end
                seen_vertices << other_v
            end
        
            return new, removed, updated
        end
    end
end

