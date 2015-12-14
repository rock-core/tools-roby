module Roby
    module Relations
        # This class manages the graph defined by an object relation in Roby.
        # 
        # Relation graphs are managed in hierarchies (for instance, in
        # EventStructure, Precedence is a superset of CausalLink, and CausalLink a
        # superset of both Forwarding and Signal). In this hierarchy, at each
        # level, an edge cannot be present in more than one graph. Nonetheless, it
        # is possible for a parent relation to have an edge which is present in
        # none of its children.
        #
        # Each relation define two things:
        # * a graph, which is represented by the Relations::Graph instance itself
        # * support methods that are defined on the vertices of the relation. They 
        #   allow to manage the vertex in its relations easily. Those methods are
        #   defined in a separate module (see {#support})
        #
        # In general, relations are part of a Relations::Space instance, which manages
        # the set of relations whose vertices are of the same kind (for instance
        # TaskStructure manages all relations whose vertices are Task instances).
        # In these cases, Relations::Space#relation allow to define new relations easily.
        class Graph < BidirectionalDirectedAdjacencyGraph
            extend Models::Graph

            # An object that is called for relation modifications
            attr_reader :observer

            def remove(vertex)
                Roby.warn_deprecated "Graph#remove is deprecated, use #remove_vertex instead"
                remove_vertex(vertex)
            end

            def link(a, b, info)
                Roby.warn_deprecated "Graph#link is deprecated, use #add_edge instead"
                add_edge(a, b, info)
            end

            def linked?(parent, child)
                Roby.warn_deprecated "Graph#linked? is deprecated, use #add_edge instead"
                has_edge?(parent, child)
            end

            def unlink(parent, child)
                Roby.warn_deprecated "Graph#unlink is deprecated, use #remove_edge instead"
                remove_edge(parent, child)
            end

            def reachable?(u, v)
                depth_first_visit(u) { |o| return true if o == v }
                false
            end

            def add_edge(a, b, info)
                if !try_updating_existing_edge_info(a, b, info)
                    super
                end
            end

            def to_s
                "#{self.class.name}:#{object_id.to_s(16)}"
            end

            def inspect; to_s end

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
                    elsif !graph.has_vertex?(m_parent) || !graph.has_vertex?(m_child) || !graph.has_edge?(m_parent, m_child)
                        return [:missing_edge, parent, child]
                    elsif edge_info(parent, child) != graph.edge_info(m_parent, m_child)
                        return [:differing_edge_info, parent, child]
                    end
                end
                nil
            end

            # Replaces +from+ by +to+. This means +to+ takes the role of +from+ in
            # all edges +from+ is involved in. +from+ is removed from the graph.
            def replace_vertex(from, to)
                from.each_parent_vertex(self) do |parent|
                    if parent != to && !has_edge?(parent, to)
                        add_edge(parent, to, parent[from, self])
                    end
                end
                from.each_child_vertex(self) do |child|
                    if to != child && !has_edge?(to, child)
                        add_edge(to, child, from[child, self])
                    end
                end
                remove(from)
            end

            def each_parent_vertex(object, &block)
                Roby.warn_deprecated "#each_parent_vertex has been replaced by #each_in_neighbour"
                rgl_graph.each_in_neighbour(object, &block)
            end

            def each_child_vertex(object, &block)
                Roby.warn_deprecated "#each_child_vertex has been replaced by #each_out_neighbour"
                rgl_graph.each_out_neighbour(object, &block)
            end

            def merge!(graph)
                merge(graph)
                graph.clear
            end

            def copy_to(target)
                Roby.warn_deprecated "Graph#copy_to is deprecated, use #merge instead (WARN: a.copy_to(b) is b.merge(a) !"
                target.merge(self)
            end

            def size
                Roby.warn_deprecated "Graph#size is deprecated, use #num_vertices instead"
                num_vertices
            end

            def include?(object)
                Roby.warn_deprecated "Graph#include? is deprecated, use #has_vertex? instead"
                has_vertex?(object)
            end

            # The relation parent (if any). See #superset_of.
            attr_accessor :parent
            # The set of graphs that are directly children of self in the graph
            # hierarchy. They are subgraphs of self, but not all the existing
            # subgraphs of self
            #
            # @see recursive_subsets
            attr_reader   :subsets

            # Compute the set of all graphs that are subsets of this one in the
            # subset hierarchy
            def recursive_subsets
                result = Set.new
                queue = subsets.to_a.dup
                while !queue.empty?
                    g = queue.shift
                    result << g
                    queue.concat(g.subsets.to_a)
                end
                result
            end

            # Creates a relation graph with the given name and options. The
            # following options are recognized:
            # +dag+:: 
            #   if the graph is a DAG. If true, add_relation will check that
            #   no cycle is created
            # +subsets+:: 
            #   a set of Relations::Graph objects that are children of this one.
            #   See #superset_of.
            # +distributed+:: 
            #   if this relation graph should be seen by remote hosts
            def initialize(
                observer: nil,
                distribute: self.class.distribute?,
                dag: self.class.dag?,
                weak: self.class.weak?,
                strong: self.class.strong?,
                copy_on_replace: self.class.copy_on_replace?,
                noinfo: !self.class.embeds_info?,
                subsets: Set.new)

                @observer = observer
                @distribute = distribute
                @dag     = dag
                @weak    = weak
                @strong  = strong
                @copy_on_replace = copy_on_replace
                @embeds_info = !noinfo

                # If the relation is a single-child relation, it expects to have
                # this ivar set
                if respond_to?(:single_child_accessor)
                    @single_child_accessor = "@#{self.class.child_name}"
                end

                @subsets = Set.new
                subsets.each { |g| superset_of(g) }

                super()
            end

            # True if this relation graph is a DAG
            attr_predicate :dag
            # True if this relation should be seen by remote peers
            attr_predicate :distribute
            # If this relation is weak. Weak relations can be removed without major
            # consequences. This is mainly used during plan garbage collection to
            # break cross-relations cycles (cycles which exist in the graph union
            # of all the relation graphs).
            attr_predicate :weak
            # If this relation is strong. Strong relations mark parts of the plan
            # that can't be exchanged bit-by-bit. I.e. plan.replace_task will ignore
            # those relations.
            attr_predicate :strong
            # If this relation embeds some additional information
            attr_predicate :embeds_info?
            # If true, a task A that is being replaced by a task B will *not* have
            # the links in this relation graph removed. Instead, they simply get
            # copied to A
            attr_predicate :copy_on_replace

            # True if this relation does not have a parent
            def root_relation?; !parent end

            # @api private
            #
            # Updates the edge information of an existing info, or does nothing
            # if the edge does not exist
            #
            # If the edge has a non-nil info already, the graph's #merge_info is
            # called to merge the existing and new information. If #merge_info
            # returns nil, the update is aborted
            #
            # @param from the edge parent object
            # @param to the edge child object
            # @param info the new edge info
            # @return [Boolean] true if the edge existed and false otherwise
            def try_updating_existing_edge_info(from, to, info)
                return false if !has_edge?(from, to)

                if !(old_info = edge_info(from, to)).nil?
                    if old_info != info && !(info = merge_info(from, to, old_info, info))
                        raise ArgumentError, "trying to change edge information in #{self} for #{from} => #{to}: old was #{old_info} and new is #{info}"
                    end
                end
                set_edge_info(from, to, info)
                true
            end

            # Add an edge between +from+ and +to+. The relation is added on all
            # parent relation graphs as well. If #dag? is true on +self+ or on one
            # of its parents, the method will raise {CycleFoundError} in case the new
            # edge would create a cycle.
            #
            # If +from+ or +to+ define the following hooks:
            #   adding_parent_object(parent, relations, info)
            #   adding_child_object(child, relations, info)
            #   added_parent_object(parent, relations, info)
            #   added_child_object(child, relations, info)
            #
            # then these hooks get respectively called before and after having
            # added the relation, where +relations+ is the set of
            # Relations::Graph
            # instances where the edge has been added. It can be either [+self+] if
            # the edge does not already exist in it, or [+self+, +parent+,
            # <tt>parent.parent</tt>, ...] if the parent, grandparent, ... graphs
            # do not include the edge either.
            def add_relation(from, to, info = nil)
                # First check if we're trying to change the edge information
                # rather than creating a new edge
                if try_updating_existing_edge_info(from, to, info)
                    return
                end

                new_relations = []
                new_relations_ids = []
                rel     = self
                while rel
                    if !rel.has_edge?(from, to)
                        new_relations << rel
                        new_relations_ids << rel.class
                    end
                    rel = rel.parent
                end

                if !new_relations.empty?
                    if observer
                        observer.adding_edge(from, to, new_relations_ids, info)
                    end
                    for rel in new_relations
                        rel.add_edge(from, to, (info if self == rel))
                    end
                    if observer
                        observer.added_edge(from, to, new_relations_ids, info)
                    end
                end
            end

            # Set the information of an object relation
            def set_edge_info(from, to, info)
                if observer
                    observer.updating_edge_info(from, to, self.class, info)
                end
                super
                if observer
                    observer.updated_edge_info(from, to, self.class, info)
                end
            end

            # Method used in {#add_relation} and {#add_edge} to merge existing
            # information with new information
            #
            # It is safe to raise from within this method
            #
            # @return [nil,Object] if nil, the update is aborted. If non-nil,
            #   it is the new information
            def merge_info(from, to, old, new)
                raise ArgumentError, "cannot update edge information in #{self}: #merge_info is not implemented"
            end

            # Remove the relation between +from+ and +to+, in this graph and in its
            # parent graphs as well.
            #
            # If +from+ or +to+ define the following hooks:
            #   removing_child_object(child, relations)
            #   removed_child_object(child, relations)
            #
            # then these hooks get respectively called once before and once after
            # having removed the relation, where +relations+ is the set of
            # Relations::Graph instances where the edge has been removed. It is always
            # <tt>[self, parent, parent.parent, ...]</tt> up to the root relation
            # which is a superset of +self+.
            def remove_relation(from, to)
                if !has_edge?(from, to)
                    return
                end

                rel = self
                relations, relations_ids = [], []
                while rel
                    relations << rel
                    relations_ids << rel.class
                    rel = rel.parent
                end

                if observer
                    observer.removing_edge(from, to, relations_ids)
                end
                for rel in relations
                    rel.remove_edge(from, to)
                end
                if observer
                    observer.removed_edge(from, to, relations_ids)
                end
            end

            # Returns true if +relation+ is included in this relation (i.e. it is
            # either the same relation or one of its children)
            #
            # See also #superset_of
            def subset?(relation)
                self.eql?(relation) || subsets.any? { |subrel| subrel.subset?(relation) }
            end

            # The root in this graph's hierarchy
            def root_graph
                g = self
                while g.parent
                    g = g.parent
                end
                g
            end

            # @deprecated use {#has_edge_in_hierarchy?}
            def linked_in_hierarchy?(source, target)
                Roby.warn_deprecated "#linked_in_hierarchy? is deprecated, use #has_edge_in_hierarchy? instead"
            end

            # Tests the presence of an edge in this graph or in its supersets
            #
            # See #superset_of for a description of the parent mechanism
            def has_edge_in_hierarchy?(source, target)
                root_graph.has_edge?(source, target)
            end

            # Declare that +self+ is a superset of +relation+. Once this is done,
            # the system manages two constraints:
            # * all new relations added in +relation+ are also added in +self+
            # * it is not allowed for an edge to exist in two different subsets of
            #   +self+
            # * of course, if +self+ is a DAG, then in effect +relation+ is constrained
            #   to be one as well.
            #
            # One single graph can be the superset of multiple subgraphs (these are
            # stored in the #subsets attribute), but one graph can have only one
            # parent (#parent).
            def superset_of(relation)
                relation.each_edge do |source, target, info|
                    if has_edge_in_hierarchy?(source, target)
                        raise ArgumentError, "relation and self already share an edge"
                    end
                end

                relation.parent = self
                subsets << relation

                # Copy the relations of the child into this graph
                relation.each_edge do |source, target, info|
                    source.add_child_object(target, self, info)
                end
            end
        end
    end
end

