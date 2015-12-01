require 'utilrb/object/attribute'
require 'roby_bgl'
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
            graphs = []
            each_graph { |rel| graphs << rel }
            for g in graphs
                g.remove(self)
            end
	end

        def singleton_set
            @singleton_set ||= [self].to_set.freeze
        end

	# Returns the connected component +self+ is part of in +graph+
	def component(graph)
	    relation_graphs[graph].components([self], false).first || singleton_set
	end
	# Returns the vertex set which are reachable from +self+ in +graph+
	def generated_subgraph(graph)
	    relation_graphs[graph].generated_subgraphs([self], false).first || singleton_set
	end
	# Returns the vertex set which can reach +self+ in +graph+
	def reverse_generated_subgraph(graph)
	    relation_graphs[graph].reverse.generated_subgraphs([self], false).first || singleton_set
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

    # Base class for Graph and the graph-view objects (Reverse and Undirected)
    module GraphCommonAlgorithms
        # This performs an algorithm in which a given value is propagated (a la
        # #inject) along the graph, forking (calling #fork on the value) each
        # time there is a fork in the graph and merging (calling #merge) each
        # time the forks meet again
        def fork_merge_propagation(seed, value, options = Hash.new)
            options = Kernel.validate_options options, vertex_visitor: nil
            vertex_visitor = options[:vertex_visitor]
            forks  = Hash.new
            merges = Hash.new

            reset_prune

            tips = Hash.new

            queue = [[seed, value]]
            while !queue.empty?
                while !queue.empty?
                    seed, value = queue.shift
                    if vertex_visitor
                        vertex_visitor.call(seed, value)
                        if pruned?
                            reset_prune
                            next
                        end
                    end
                    if leaf?(seed)
                        tips[seed] = value
                    end

                    last_vertex = nil
                    each_dfs(seed, BGL::Graph::ALL) do |from, to, info|
                        if last_vertex && (from != last_vertex)
                            tips[last_vertex] = value
                        end
                        last_vertex = to

                        # Reset value if we backtracked to a fork
                        out_degree = self.out_degree(from)
                        if out_degree > 1
                            forks[from] ||= value
                            value = forks[from].fork
                        end

                        # Update value based on the edge information
                        value = yield(from, to, value)
                        if pruned?
                            last_vertex = nil
                            next
                        end

                        # And take care of merges
                        in_degree = self.in_degree(to)
                        if in_degree > 1
                            merges[to] ||= []
                            merges[to] << value
                            if merges[to].size == in_degree
                                value = merges.delete(to).inject do |value, v|
                                    value.merge(v)
                                end
                            else
                                # Do not save this tip, it will be given for
                                # processing later on when we can merge
                                last_vertex = nil
                                prune
                            end
                        end
                        if vertex_visitor && last_vertex
                            vertex_visitor.call(last_vertex, value)
                            if pruned?
                                last_vertex = nil
                                next
                            end
                        end
                    end
                    if last_vertex
                        tips[last_vertex] = value
                    end
                end

                queue = merges.map do |v, values|
                    [v, values.inject { |value, v| value.merge(v) }]
                end
                merges.clear
            end

            tips
        end
    end

    class Graph
        include GraphCommonAlgorithms

	# This class is an adaptor which transforms a directed graph by
	# swapping its edges
	class Reverse
            include GraphCommonAlgorithms

            def root?(vertex)
                @__bgl_real_graph__.leaf?(vertex)
            end

            def leaf?(vertex)
                @__bgl_real_graph__.root?(vertex)
            end

            def in_degree(vertex)
                @__bgl_real_graph__.out_degree(vertex)
            end

            def out_degree(vertex)
                @__bgl_real_graph__.in_degree(vertex)
            end
            
            def prune
                @__bgl_real_graph__.prune
            end

            def pruned?
                @__bgl_real_graph__.pruned?
            end

            def reset_prune
                @__bgl_real_graph__.reset_prune
            end

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
            merge(source)
	end

        def size
            Roby.warn_deprecated "Graph#size is deprecated, use #num_vertices instead"
            num_vertices
        end

        def copy_to(target)
            target.merge(self)
        end

        def find_edge_difference(graph, mapping)
            if graph.num_edges != num_edges
                return [:num_edges_differ]
            end

            each_edge do |parent, child|
                m_parent, m_child = mapping[parent], mapping[child]
                if !m_parent
                    return [:missing_mapping, parent]
                elsif !m_child
                    return [:missing_mapping, child]
                elsif !graph.include?(m_parent) || !graph.include?(m_child) || !graph.linked?(m_parent, m_child)
                    return [:missing_edge, parent, child]
                elsif edge_info(parent, child) != graph.edge_info(m_parent, m_child)
                    return [:differing_edge_info, parent, child]
                end
            end
            nil
        end

        def merge(target)
            target.each_vertex { |v| insert(v) }
            target.each_edge { |s, t, i| link(s, t, i) }
        end

        def merge!(target)
            merge(target)
            target.clear
        end

	# Replaces +from+ by +to+. This means +to+ takes the role of +from+ in
	# all edges +from+ is involved in. +from+ is removed from the graph.
	def replace_vertex(from, to)
	    from.each_parent_vertex(self) do |parent|
                if parent != to && !linked?(parent, to)
                    link(parent, to, parent[from, self])
                end
	    end
	    from.each_child_vertex(self) do |child|
                if to != child && !linked?(to, child)
                    link(to, child, from[child, self])
                end
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

	    (other.enum_for(:each_vertex).to_set == enum_for(:each_vertex).to_set) && 
		(other.enum_for(:each_edge).to_set == enum_for(:each_edge).to_set)
	end

        def pretty_print(pp)
            pp.text "#{size} vertices in graph"

            tasks = Hash.new
            each_vertex do |from|
                tasks[from] = from.to_s
            end

            pp.nest(4) do
                tasks.sort_by { |_, v| v }.each do |parent, parent_name|
                    pp.breakable
                    pp.text parent_name
                    pp.nest(4) do
                        children = Array.new
                        parent.each_child_vertex(self) do |child|
                            children << [child.to_s, parent[child, self].to_s]
                        end
                        children.sort_by(&:first).each do |child_name, child_info|
                            pp.breakable
                            pp.text "=> #{child_name} (#{child_info})"
                        end
                    end
                end
            end
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
        def difference(other_graph, self_vertices, &mapping)
            mapping ||= lambda { |v| v }
            other_vertices = Set.new

            new, removed, updated = Set.new, Set.new, Set.new

            seen_vertices    = Set.new
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
                        if other_graph.edge_info(other_parent, other_v) != edge_info(self_parent, self_v)
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
                        if other_graph.edge_info(other_v, other_child) != edge_info(self_v, self_child)
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

