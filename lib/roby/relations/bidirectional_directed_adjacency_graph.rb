# frozen_string_literal: true

require "rgl/mutable"
require "set"

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

            attr_reader :forward_edges_with_info, :backward_edges

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

            class IdentityHash < Hash
                def initialize
                    super
                    compare_by_identity
                end
            end

            # This singleton is used in {#dedupe} to have only one single empty
            # hash
            @@identity_hash_singleton = IdentityHash.new
            @@identity_hash_singleton.freeze

            # Returns a new empty DirectedAdjacencyGraph which has as its edgelist
            # class the given class. The default edgelist class is Set, to ensure
            # set semantics for edges and vertices.
            #
            # If other graphs are passed as parameters their vertices and edges are
            # added to the new graph.
            #
            def initialize
                @forward_edges_with_info = IdentityHash.new
                @backward_edges = IdentityHash.new
            end

            # Copy internal vertices_dict
            #
            def initialize_copy(orig)
                super
                forward_edges_with_info = @forward_edges_with_info
                @forward_edges_with_info = IdentityHash.new
                forward_edges_with_info.each do |u, out_edges|
                    mapped_out_edges = IdentityHash.new
                    out_edges.each do |v, info|
                        info = info.dup if info
                        mapped_out_edges[v] = info
                    end
                    @forward_edges_with_info[u] = mapped_out_edges
                end

                backward_edges = @backward_edges
                @backward_edges = IdentityHash.new
                backward_edges.each do |v, in_edges|
                    @backward_edges[v] = in_edges.dup
                end
            end

            # Make sure that self and source share identical hashes when
            # possible
            def dedupe(source)
                all_identical = (@forward_edges_with_info.size ==
                                 source.forward_edges_with_info.size)
                # Use #keys.each instead of #each_key as we are modifying in-place
                @forward_edges_with_info.keys.each do |v| # rubocop:disable Style/HashEachMethods
                    self_out_edges   = @forward_edges_with_info[v]
                    source_out_edges = source.forward_edges_with_info[v]
                    if self_out_edges.empty?
                        all_identical &&= source_out_edges.empty?
                        @forward_edges_with_info[v] = @@identity_hash_singleton
                    elsif self_out_edges == source_out_edges
                        @forward_edges_with_info[v] = source_out_edges.freeze
                    else
                        all_identical = false
                    end
                end

                if all_identical
                    @forward_edges_with_info = source.forward_edges_with_info.freeze
                    @backward_edges = source.backward_edges.freeze
                    return
                end

                # Use #keys.each instead of #each_key as we are modifying in-place
                @backward_edges.keys.each do |v| # rubocop:disable Style/HashEachMethods
                    self_in_edges   = @backward_edges[v]
                    source_in_edges = source.backward_edges[v]
                    if self_in_edges.empty?
                        @backward_edges[v] = @@identity_hash_singleton
                    elsif self_in_edges == source_in_edges
                        @backward_edges[v] = source_in_edges.freeze
                    end
                end
            end

            # Iterator for the keys of the vertices list hash.
            #
            def each_vertex(&b)
                @forward_edges_with_info.each_key(&b)
            end

            def each_edge
                return enum_for(__method__) unless block_given?

                @forward_edges_with_info.each do |u, out_edges|
                    out_edges.each do |v, info|
                        yield(u, v, info)
                    end
                end
            end

            def to_a
                @forward_edges_with_info.keys
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

            def same_structure?(graph)
                graph.instance_variable_get(:@backward_edges) == backward_edges
            end

            def move_edges(source, target)
                source_out = @forward_edges_with_info[source]
                return unless source_out

                source_in = @backward_edges[source]
                target_out = (@forward_edges_with_info[target] ||= IdentityHash.new)
                target_in = (@backward_edges[target] ||= IdentityHash.new)

                source_out.each_key do |child|
                    child_in = @backward_edges[child]
                    child_in.delete(source)
                    child_in[target] = nil
                end
                source_in.each_key do |parent|
                    child_out = @forward_edges_with_info[parent]
                    child_out[target] = child_out.delete(source)
                end
                target_out.merge!(source_out)
                target_in.merge!(source_in)
                source_out.clear
                source_in.clear
            end

            def each_out_neighbour(v, &b)
                if (v_out = @forward_edges_with_info[v])
                    v_out.each_key(&b)
                elsif !block_given?
                    enum_for(__method__, v)
                end
            end
            alias each_adjacent each_out_neighbour

            def out_neighbours(v)
                each_out_neighbour(v).to_a
            end
            alias adjacent_vertices out_neighbours

            def out_degree(v)
                if (v_out = @forward_edges_with_info[v])
                    v_out.size
                else 0
                end
            end

            def each_in_neighbour(v, &b)
                if (v_in = @backward_edges[v])
                    v_in.each_key(&b)
                elsif !block_given?
                    enum_for(__method__, v)
                end
            end

            def in_neighbours(v)
                each_in_neighbour(v).to_a
            end

            def in_degree(v)
                @backward_edges[v]&.size || 0
            end

            def replace(g)
                @forward_edges_with_info.replace(g.instance_variable_get(:@forward_edges_with_info))
                @backward_edges.replace(g.instance_variable_get(:@backward_edges))
            end

            def root?(v)
                in_degree(v) == 0
            end

            def leaf?(v)
                out_degree(v) == 0
            end

            def vertices
                @forward_edges_with_info.keys
            end

            def num_vertices
                @forward_edges_with_info.size
            end

            def num_edges
                @forward_edges_with_info.each_value.inject(0) do |count, out_edges|
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
            def has_vertex?(v)
                @forward_edges_with_info.key?(v)
            end

            # Complexity is O(1), if a Set is used as adjacency list. Otherwise,
            # complexity is O(out_degree(v)).
            #
            # ---
            # MutableGraph interface.
            #
            def has_edge?(u, v)
                @forward_edges_with_info[u]&.key?(v)
            end

            # See MutableGraph#add_vertex.
            #
            # If the vertex is already in the graph (using eql?), the method does
            # nothing.
            #
            def add_vertex(v)
                @forward_edges_with_info[v] ||= IdentityHash.new
                @backward_edges[v] ||= IdentityHash.new
            end

            # See MutableGraph#add_edge.
            #
            def add_edge(u, v, i = nil)
                raise ArgumentError, "cannot add self-referencing edges" if u == v

                u_out = (@forward_edges_with_info[u] ||= IdentityHash.new)
                @backward_edges[u] ||= IdentityHash.new
                @forward_edges_with_info[v] ||= IdentityHash.new
                v_in = (@backward_edges[v] ||= IdentityHash.new)

                u_out[v] = i
                v_in[u] = nil
            end

            # See MutableGraph#remove_vertex.
            #
            def remove_vertex(v)
                v_out = @forward_edges_with_info.delete(v)
                return unless v_out

                v_in = @backward_edges.delete(v)

                v_out.each_key do |child|
                    @backward_edges[child].delete(v)
                end
                v_in.each_key do |parent|
                    @forward_edges_with_info[parent].delete(v)
                end
                !v_out.empty? || !v_in.empty?
            end

            # See MutableGraph::remove_edge.
            #
            def remove_edge(u, v)
                u_out = @forward_edges_with_info[u]
                if u_out
                    u_out.delete(v)
                    @backward_edges[v].delete(u)
                end
            end

            def merge(graph)
                g_forward  = graph.instance_variable_get(:@forward_edges_with_info)
                g_backward = graph.instance_variable_get(:@backward_edges)
                g_forward.each do |g_u, g_out_edges|
                    if !(out_edges = @forward_edges_with_info[g_u])
                        @forward_edges_with_info[g_u] = g_out_edges.dup
                    else
                        out_edges.merge!(g_out_edges)
                    end
                end
                g_backward.each do |g_v, g_in_edges|
                    if !(in_edges = @backward_edges[g_v])
                        @backward_edges[g_v] = g_in_edges.dup
                    else
                        in_edges.merge!(g_in_edges)
                    end
                end
            end

            def clear
                @forward_edges_with_info.clear
                @backward_edges.clear
            end

            def edge_info(parent, child)
                @forward_edges_with_info.fetch(parent).fetch(child)
            rescue KeyError
                raise ArgumentError, "no edge #{parent} => #{child} in #{self}"
            end

            def set_edge_info(parent, child, info)
                parent_out = @forward_edges_with_info.fetch(parent)
                unless parent_out.key?(child)
                    raise ArgumentError, "no edge #{parent} => #{child} in #{self}"
                end

                parent_out[child] = info
            rescue KeyError
                raise ArgumentError, "no edge #{parent} => #{child} in #{self}"
            end

            def reverse
                result = dup
                result.reverse!
                result
            end

            def reverse!
                @forward_edges_with_info.each do |u, out_edges|
                    out_edges.each do |v, info|
                        @backward_edges[v][u] = info
                        out_edges[v] = nil
                    end
                end
                @forward_edges_with_info, @backward_edges =
                    @backward_edges, @forward_edges_with_info
            end

            class Inconsistent < RuntimeError; end

            def verify_consistency
                @forward_edges_with_info.each do |v, out_edges|
                    unless @backward_edges.key?(v)
                        raise Inconsistent,
                              "#{v} has an entry in the forward-edge set, "\
                              "but not in the backward-edge"
                    end

                    out_edges.each do |out_e, _info|
                        if !@backward_edges.key?(out_e)
                            raise Inconsistent,
                                  "#{out_e} is listed as an out-neighbour of #{v} "\
                                  "but #{out_e} is not included in the graph"
                        elsif !@backward_edges[out_e].key?(v)
                            raise Inconsistent,
                                  "#{out_e} is listed as an out-neighbour of #{v} "\
                                  "but #{out_e} does not list it as in-neighbour"
                        end
                    end
                end
                @backward_edges.each do |v, in_edges|
                    unless @forward_edges_with_info.key?(v)
                        raise Inconsistent,
                              "#{v} has an entry in the forward-edge set, "\
                              "but not in the backward-edge"
                    end

                    in_edges.each do |in_e, _|
                        if !@forward_edges_with_info[in_e]
                            raise Inconsistent,
                                  "#{in_e} is listed as an in-neighbour of #{v} "\
                                  "but is not included in the graph"
                        elsif !@forward_edges_with_info[in_e].key?(v)
                            raise Inconsistent,
                                  "#{in_e} is listed as an in-neighbour of #{v} "\
                                  "but #{in_e} does not list it as out-neighbour"
                        end
                    end
                end
            end

            def freeze
                @vertices_dict.each_value do |out_e, in_e|
                    out_e.freeze
                    in_e.freeze
                end
                @vertices_dict.freeze
                @edge_info_map.freeze
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
                mapping ||= ->(v) { v }
                other_vertices = Set.new

                new = []
                removed = []
                updated = []

                seen_vertices    = IdentityHash.new
                seen_connections = IdentityHash.new
                self_vertices.each do |self_v|
                    other_v = mapping[self_v]
                    other_vertices << other_v

                    each_in_neighbour(self_v) do |self_parent|
                        # If we already worked on +self_parent+, this connection has
                        # already been taken into account
                        next if seen_vertices.key?(self_parent)

                        other_parent = mapping[self_parent]
                        if other_graph.has_edge?(other_parent, other_v)
                            if other_graph.edge_info(other_parent, other_v) !=
                               edge_info(self_parent, self_v)
                                updated << [self_parent, self_v]
                            end
                            (seen_connections[other_parent] ||= IdentityHash.new)[other_v] = nil
                        else
                            new << [self_parent, self_v]
                        end
                    end

                    each_out_neighbour(self_v) do |self_child|
                        # If we already worked on +self_child+, this connection has
                        # already been taken into account
                        next if seen_vertices.key?(self_child)

                        other_child = mapping[self_child]
                        if other_graph.has_edge?(other_v, other_child)
                            if other_graph.edge_info(other_v, other_child) !=
                               edge_info(self_v, self_child)
                                updated << [self_v, self_child]
                            end
                            (seen_connections[other_v] ||= IdentityHash.new)[other_child] = nil
                        else
                            new << [self_v, self_child]
                        end
                    end

                    seen_vertices[self_v] = nil
                end

                seen_vertices.clear
                other_vertices.each do |other_v|
                    other_graph.each_in_neighbour(other_v) do |other_parent|
                        next if seen_vertices.key?(other_parent)

                        if !(out_seen = seen_connections[other_parent]) || !out_seen.key?(other_v)
                            removed << [other_parent, other_v]
                        end
                    end
                    other_graph.each_out_neighbour(other_v) do |other_child|
                        next if seen_vertices.key?(other_child)

                        if !(out_seen = seen_connections[other_v]) || !out_seen.key?(other_child)
                            removed << [other_v, other_child]
                        end
                    end
                    seen_vertices[other_v] = nil
                end

                [new, removed, updated]
            end
        end
    end
end
