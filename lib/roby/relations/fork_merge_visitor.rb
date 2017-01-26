module Roby
    module Relations
        # @api private
        #
        # A graph visitor which propagates a value through a subgraph of an
        # acyclic graph, copying the value using #fork at graph forks, and
        # merging them back with #merge when reaching a merge point
        class ForkMergeVisitor < RGL::DFSVisitor
            # The vertex from which we start visiting
            attr_reader :origin

            # The neighbours of this vertex that should be visited.
            attr_reader :origin_neighbours

            # A mapping from vertex to the propagated object for this vertex
            attr_reader :vertex_to_object

            # The pending merges, i.e. a collection of objects gathered so far
            # at a merge point
            attr_reader :pending_merges

            # The in-degree of each node in the subgraph defined by {#origin}
            # and {#origin_neighbours}
            attr_reader :in_degree

            # The out-degree of each node in the subgraph defined by {#origin}
            # and {#origin_neighbours}
            attr_reader :out_degree

            # @param graph the directed graph we propagate the value in
            # @param origin the vertex from which to propagate
            # @param [#include?] origin_neighbours the neighbours of 'origin' to
            #   propagate towards
            # @param [#fork,#merge] object the object to propagate in the graph
            def initialize(graph, object, origin, origin_neighbours = graph.out_neighbours(origin))
                super(graph)
                @origin = origin
                @origin_neighbours = origin_neighbours

                @vertex_to_object = Hash[origin => object]
                @pending_merges = Hash.new { |h, k| h[k] = Array.new }

                @in_degree, @out_degree = compute_in_out_degrees(origin, origin_neighbours)
            end

            def visit
                graph.depth_first_visit(origin, self) {}
            end

            # A visitor that counts the in/out degree of vertices contained in a
            # subgraph
            class SubgraphDegreeCounter < RGL::DFSVisitor
                attr_reader :out_degree
                attr_reader :in_degree
                def initialize(graph)
                    @out_degree = Hash.new(0)
                    @in_degree = Hash.new(0)
                    super(graph)
                end
                def handle_tree_edge(u, v)
                    out_degree[u] += 1
                    in_degree[v] += 1
                end
                def handle_back_edge(u, v)
                    out_degree[u] += 1
                    in_degree[v] += 1
                end
                def handle_forward_edge(u, v)
                    out_degree[u] += 1
                    in_degree[v] += 1
                end
            end

            # Computes the in and out degree of the subgraph starting at
            # 'origin', following the out-edges of 'origin' that go towards
            # 'origin_neighbours'
            def compute_in_out_degrees(origin, origin_neighbours)
                visitor = SubgraphDegreeCounter.new(graph)
                origin_neighbours.each do |v|
                    graph.depth_first_visit(v, visitor) { }
                end
                in_degree, out_degree = visitor.in_degree, visitor.out_degree

                in_degree[origin] = 0
                out_degree[origin] = origin_neighbours.size
                origin_neighbours.each do |v|
                    in_degree[v] += 1
                end
                return in_degree, out_degree
            end

            def follow_edge?(u, v)
                if u == origin
                    return if !origin_neighbours.include?(v)
                end

                degree = in_degree[v]
                if degree == 1
                    true
                else
                    (pending_merges[v].size + 1) == degree
                end
            end

            def handle_forward_edge(u, v)
                if u == origin
                    return if !origin_neighbours.include?(v)
                end

                obj = vertex_to_object.fetch(u)
                if obj
                    if out_degree[u] > 1
                        obj = fork_object(obj)
                    end
                    obj = propagate_object(u, v, obj)
                end
                if in_degree[v] > 1
                    pending_merges[v] << obj
                else
                    vertex_to_object[v] = obj
                end
            end

            def handle_tree_edge(u, v)
                obj = vertex_to_object.fetch(u)
                if obj
                    if out_degree[u] > 1
                        obj = fork_object(obj)
                    end
                    obj = propagate_object(u, v, obj)
                end

                if in_degree[v] > 1
                    obj = (pending_merges.delete(v) << obj).compact.inject { |a, b| a.merge(b) }
                end
                vertex_to_object[v] = obj
            end

            def handle_back_edge(u, v)
                raise "#handle_back_edge should never happen in a fork-merge traversal"
            end

            def propagate_object(u, v, obj)
                obj
            end

            def fork_object(obj)
                obj.fork
            end
        end
    end
end

