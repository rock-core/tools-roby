require 'rgl/mutable'
require 'set'

module Roby
    module Relations
        # A RGL-compatible bidirectional version of the adjacency graph,
        # with edge information
        #
        # Unlike RGL classes, it does not raise if trying to query a vertex
        # that is not in the graph, e.g.
        #
        #     graph.out_neighbours(random_object) -> Set.new
        class BidirectionalDirectedAdjacencyGraph
            include RGL::MutableGraph

            # A map of edge pair (u,v) to the edge information
            attr_reader :edge_info_map

            # Shortcut for creating a DirectedAdjacencyGraph:
            #
            #  RGL::DirectedAdjacencyGraph[1,2, 2,3, 2,4, 4,5].edges.to_a.to_s =>
            #    "(1-2)(2-3)(2-4)(4-5)"
            #
            def self.[](*a)
                result = new
                a.each_slice(2) do |u, v|
                    result.add_edge(u, v)
                end
                result
            end

            # Returns a new empty DirectedAdjacencyGraph which has as its edgelist
            # class the given class. The default edgelist class is Set, to ensure
            # set semantics for edges and vertices.
            #
            # If other graphs are passed as parameters their vertices and edges are
            # added to the new graph.
            #
            def initialize(edgelist_class = Set)
                @edgelist_class = edgelist_class
                @edge_info_map = Hash.new
                @vertices_dict = Hash.new
            end

            # Copy internal vertices_dict
            #
            def initialize_copy(orig)
                super
                vertices_dict, @vertices_dict = @vertices_dict, Hash.new
                vertices_dict.each do |v, (out_edges, in_edges)|
                    @vertices_dict[v] = [out_edges.dup, in_edges.dup]
                end
                edge_info_map, @edge_info_map = @edge_info_map, Hash.new
                edge_info_map.each do |(u, v), info|
                    @edge_info_map[[u, v]] =
                        if info then info.dup
                        end
                end
            end

            # Iterator for the keys of the vertices list hash.
            #
            def each_vertex(&b)
                @vertices_dict.each_key(&b)
            end

            def each_edge
                return enum_for(__method__) if !block_given?
                edge_info_map.each do |(u, v), info|
                    yield(u, v, info)
                end
            end

            def to_a
                @vertices_dict.keys
            end

            def ==(other)
                equal?(other)
            end

            def hash
                object_id
            end

            def eql?(other)
                equal?(other)
            end

            def move_edges(source, target)
                source_out, source_in = @vertices_dict[source]
                return if !source_out

                target_out, target_in = (@vertices_dict[target] ||= [@edgelist_class.new, @edgelist_class.new])
                source_out.each do |child|
                    edge_info_map[[target, child]] = edge_info_map.delete([source,child])
                end
                source_in.each do |parent|
                    edge_info_map[[parent,target]] = edge_info_map.delete([parent,source])
                end
                target_out.merge(source_out)
                target_in.merge(source_in)
                source_out.clear
                source_in.clear
            end

            def each_out_neighbour(v, &b)
                if adjacency_list = @vertices_dict[v]
                    adjacency_list[0].each(&b)
                elsif !block_given?
                    enum_for(__method__, v)
                end
            end
            alias :each_adjacent :each_out_neighbour

            def out_neighbours(v)
                if adjacency_list = @vertices_dict[v]
                    adjacency_list[0]
                else @edgelist_class.new
                end
            end
            alias :adjacent_vertices :out_neighbours

            def out_degree(v)
                if adjacency_list = @vertices_dict[v]
                    adjacency_list[0].size
                else 0
                end
            end

            def each_in_neighbour(v, &b)
                if adjacency_list = @vertices_dict[v]
                    adjacency_list[1].each(&b)
                elsif !block_given?
                    enum_for(__method__, v)
                end
            end

            def in_neighbours(v)
                if adjacency_list = @vertices_dict[v]
                    adjacency_list[1]
                else @edgelist_class.new
                end
            end

            def in_degree(v)
                if adjacency_list = @vertices_dict[v]
                    adjacency_list[1].size
                else 0
                end
            end
            
            def replace(g)
                @vertices_dict.replace(g.instance_variable_get(:@vertices_dict))
                edge_info_map.replace(g.edge_info_map)
            end

            def root?(v)
                in_degree(v) == 0
            end

            def leaf?(v)
                out_degree(v) == 0
            end

            def vertices
                @vertices_dict.keys
            end

            def num_vertices
                @vertices_dict.size
            end

            def num_edges
                @vertices_dict.each_value.inject(0) do |count, (out_edges, _)|
                    count + out_edges.size
                end
            end

            # Returns true.
            #
            def directed?
                true
            end

            # Complexity is O(1), because the vertices are kept in a Hash containing
            # as values the lists of adjacent vertices of _v_.
            #
            def has_vertex? (v)
                @vertices_dict.has_key?(v)
            end

            # Complexity is O(1), if a Set is used as adjacency list. Otherwise,
            # complexity is O(out_degree(v)).
            #
            # ---
            # MutableGraph interface.
            #
            def has_edge? (u, v)
                edge_info_map.has_key? [u,v]
            end

            # See MutableGraph#add_vertex.
            #
            # If the vertex is already in the graph (using eql?), the method does
            # nothing.
            #
            def add_vertex(v)
                @vertices_dict[v] ||= [@edgelist_class.new, @edgelist_class.new]
            end

            # See MutableGraph#add_edge.
            #
            def add_edge(u, v, i = nil)
                if u == v
                    raise ArgumentError, "cannot add self-referencing edges"
                end

                u_out, _    = (@vertices_dict[u] ||= [@edgelist_class.new, @edgelist_class.new])
                    _, v_in = (@vertices_dict[v] ||= [@edgelist_class.new, @edgelist_class.new])
                u_out << v
                v_in  << u
                edge_info_map[[u, v]] = i
            end

            # See MutableGraph#remove_vertex.
            #
            def remove_vertex(v)
                out_edges, in_edges = @vertices_dict.delete(v)
                return if !out_edges

                out_edges.each do |child|
                    edge_info_map.delete([v, child])
                    @vertices_dict[child][1].delete(v)
                end
                in_edges.each do |parent|
                    edge_info_map.delete([parent, v])
                    @vertices_dict[parent][0].delete(v)
                end
                return out_edges, in_edges
            end

            # See MutableGraph::remove_edge.
            #
            def remove_edge(u, v)
                u_out, _ = @vertices_dict[u]
                if u_out && u_out.delete?(v)
                    @vertices_dict[v][1].delete(u)
                    edge_info_map.delete([u, v])
                end
            end

            def merge(graph)
                graph_vertices = graph.instance_variable_get(:@vertices_dict)
                @vertices_dict.merge!(graph_vertices) do |_, (out_edges, in_edges), (g_out_edges, g_in_edges)|
                    out_edges.merge(g_out_edges)
                    in_edges.merge(g_in_edges)
                    [out_edges, in_edges]
                end
                edge_info_map.merge!(graph.edge_info_map)
            end

            def clear
                @vertices_dict.clear
                edge_info_map.clear
            end

            # Converts the adjacency list of each vertex to be of type _klass_. The
            # class is expected to have a new constructor which accepts an enumerable as
            # parameter.
            #
            def edgelist_class=(klass)
                @vertices_dict.keys.each do |v|
                    out_edges, in_edges = @vertices_dict[v]
                    @vertices_dict[v] = [klass.new(out_edges.to_a), klass.new(in_edges.to_a)]
                end
            end

            def edge_info(parent, child)
                edge_info_map.fetch([parent, child])
            rescue KeyError => e
                raise ArgumentError, e.message, e.backtrace
            end

            def set_edge_info(parent, child, info)
                edge_info_map[[parent, child]] = info
            end

            def reverse
                result = dup
                result.reverse!
                result
            end

            def reverse!
                @vertices_dict.keys.each do |v|
                    in_edges, out_edges = @vertices_dict[v]
                    @vertices_dict[v] = out_edges, in_edges
                end
                new_map = Hash.new
                @edge_info_map.each do |(u, v), info|
                    new_map[[v,u]] = info
                end
                @edge_info_map = new_map
            end

            class Inconsistent < RuntimeError; end

            def verify_consistency
                @vertices_dict.each do |v, (out_edges, in_edges)|
                    out_edges.each do |out_e|
                        if !@vertices_dict[out_e][1].include?(v)
                            raise Inconsistent, "#{out_e} is listed as an out-neighbour of #{v} but #{out_e} does not list it as in-neighbour"
                        elsif !edge_info_map.has_key?([v, out_e])
                            raise Inconsistent, "#{out_e} is listed as an out-neighbour of #{v} but the edge is not registered in the edge info map"
                        end
                    end
                    in_edges.each do |in_e|
                        if !@vertices_dict[in_e][0].include?(v)
                            raise Inconsistent, "#{in_e} is listed as an in-neighbour of #{v} but #{in_e} does not list it as out-neighbour"
                        elsif !edge_info_map.has_key?([in_e, v])
                            raise Inconsistent, "#{in_e} is listed as an in-neighbour of #{v} but the edge is not registered in the edge info map"
                        end
                    end
                end
            end
        end
    end
end
