# frozen_string_literal: true

module Roby
    module Relations
        # A relation graph
        #
        # Relation graphs extend the base graph class
        # {BidirectionalDirectedAdjacencyGraph} by adding the ability to
        # arrange the graphs in a hierarchy (where a 'child' is a subgraph of a
        # 'parent'), and the modification methods {#add_relation} and
        # {#remove_relation} that maintain consistency in the hierarchy.
        # Moreover, it allows to set an {#observer} object that listens to graph
        # modifications (Roby uses it to emit relation hooks on plan objects
        # when included in a {ExecutablePlan}).
        #
        # Note that the underlying methods {#add_edge} and {#remove_edge}
        # are still available in cases where the hooks should not be called
        # *and* hierarchy consistency is maintained by other means (e.g. when
        # copying a plan).
        #
        # Finally, it is possible for {#add_edge} to update an existing edge
        # info. For this purpose, a subclass has to implement the {#merge_info}
        # method which is called with the old and new info and should return the
        # merged object. The default implementation raises ArgumentError
        class Graph < BidirectionalDirectedAdjacencyGraph
            extend Models::Graph

            # True if this relation graph is a DAG
            #
            # This property is not enforced by the Graph class itself as in a
            # lot of cases it would be too expensive. When used in Roby, it is
            # either enforced by {ExecutablePlan} or when committing a
            # transaction
            attr_predicate :dag
            # True if this relation should be seen by remote peers
            attr_predicate :distribute
            # If this relation is weak
            #
            # Weak relations are not considered during garbage collection
            attr_predicate :weak
            # If this relation is strong
            #
            # Strong relations mark parts of the plan that can't be exchanged
            # bit-by-bit. I.e. {Plan#replace_task} will ignore those relations.
            attr_predicate :strong

            # If this relation embeds some additional information
            attr_predicate :embeds_info?

            # Whether edges in this relation should be copied on replacement or
            # moved. The default is to move.
            attr_predicate :copy_on_replace

            # The relation parent (if any)
            #
            # @see superset_of recursive_subsets
            attr_accessor :parent

            # The set of graphs that are directly children of self in the graph
            # hierarchy. They are subgraphs of self, but not all the existing
            # subgraphs of self
            #
            # @see superset_of recursive_subsets
            attr_reader   :subsets

            # An object that is called for relation modifications
            #
            # The relation will call the following hooks.
            #
            # Addition/removal hooks are called once per modification in the
            # relation hierarchy. They get a 'relations' array which is the list
            # of relation IDs (i.e. graph classes, e.g.
            # {TaskStructure::Dependency}) which are concerned with the
            # modification. This array is sorted from the downmost in the
            # relation hierarchy (i.e. the most specialized) up to the upmost
            # (the biggest superset).
            #
            #    adding_edge(from, to, relations, info)
            #    added_edge(from, to, relations, info)
            #
            # Before and after a new edge is added between two vertices in the
            # graph. 'info' is the edge info that is set for the edge in the
            # first element of 'relations' (the other relations get nil)
            #
            #    updating_edge(from, to, relation, info)
            #    updated_edge(from, to, relation, info)
            #
            # Before and after the edge info is set on a given edge. 'relation'
            # is a single relation ID.
            #
            #    removing_edge(from, to, relations)
            #    removed_edge(from, to, relations)
            #
            # Before and after an edge has been removed.
            attr_reader :observer

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
                subsets: Set.new
            )

                @observer = observer
                @distribute = distribute
                @dag = dag
                @weak = weak
                @strong = strong
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

            # Tests whether a vertex is reachable from this one
            #
            # This is at worst O(E), i.e. the number of vertices that are
            # reachable from the source vertex.
            #
            # If you want to do a lot of these queries, or if you want to check
            # for acyclicity, RGL offers better alternatives.
            #
            # @param [Object] u the origin vertex
            # @param [Object] v the vertex whose reachability we want to test
            #   from 'u'
            def reachable?(u, v)
                depth_first_visit(u) { |o| return true if o == v }
                false
            end

            def to_s
                "#{self.class.name}:#{object_id.to_s(16)}"
            end

            def inspect
                to_s
            end

            # Copy a subgraph of self into another graph
            #
            # This method allows to define a mapping of vertices from self
            # (source set) into vertices of another graph (target set), and
            # copies the edges that exist between the vertices of the source set
            # to edges between the corresponding vertices of target set
            #
            # @param [Graph] graph the target graph
            # @param [Hash<Object,Object>] a mapping from the subgraph vertices
            #   in self to the corresponding vertices in the target graph
            def copy_subgraph_to(graph, mappings)
                mappings.each do |v, mapped_v|
                    each_out_neighbour(v) do |child|
                        if (mapped_child = mappings[child])
                            graph.add_edge(mapped_v, mapped_child,
                                           edge_info(v, child))
                        end
                    end
                end
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
                    elsif !graph.has_vertex?(m_parent) || !graph.has_vertex?(m_child) || !graph.has_edge?(m_parent, m_child)
                        return [:missing_edge, parent, child]
                    elsif edge_info(parent, child) != graph.edge_info(m_parent, m_child)
                        return [:differing_edge_info, parent, child]
                    end
                end
                nil
            end

            # Moves a vertex relations onto another
            #
            # @param [Object] from the vertex whose relations are going to be
            #   moved
            # @param [Object] to the vertex on which the relations will be
            #   added
            # @param [Boolean] remove whether 'from' should be removed from the
            #   graph after replacement
            def replace_vertex(from, to, remove: true)
                edges = []
                each_in_neighbour(from) do |parent|
                    if parent != to
                        add_edge(parent, to, edge_info(parent, from))
                        edges << [parent, from]
                    end
                end
                each_out_neighbour(from) do |child|
                    if to != child
                        add_edge(to, child, edge_info(from, child))
                        edges << [from, child]
                    end
                end

                edges.each do |parent, child|
                    remove_relation(parent, child)
                end

                if remove
                    remove_vertex(from)
                end
            end

            # Add the vertices and edges of a graph in self
            #
            # @param [Graph] graph the graph whose relations should be added to
            #   self
            def merge!(graph)
                merge(graph)
                graph.clear
            end

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
                return false unless has_edge?(from, to)

                unless (old_info = edge_info(from, to)).nil?
                    if old_info == info
                        return true
                    elsif !(info = merge_info(from, to, old_info, info))
                        raise ArgumentError, "trying to change edge information in #{self} for #{from} => #{to}: old was #{old_info} and new is #{info}"
                    end
                end
                set_edge_info(from, to, info)
                true
            end

            # Add an edge between two objects
            #
            # Unlike {BidirectionalDirectedAdjacencyGraph#add_edge}, it will
            # update the edge info (using {#merge_info}) if the edge already
            # exists.
            #
            # @return true if a new edge was created
            def add_edge(a, b, info)
                unless try_updating_existing_edge_info(a, b, info)
                    super
                    true
                end
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
                rel = self
                while rel
                    unless rel.has_edge?(from, to)
                        new_relations << rel
                        new_relations_ids << rel.class
                    end
                    rel = rel.parent
                end

                unless new_relations.empty?
                    observer&.adding_edge(from, to, new_relations_ids, info)
                    for rel in new_relations
                        rel.add_edge(from, to, (info if self == rel))
                    end
                    observer&.added_edge(from, to, new_relations_ids, info)
                end
            end

            # Set the information of an object relation
            def set_edge_info(from, to, info)
                observer&.updating_edge_info(from, to, self.class, info)
                super
                observer&.updated_edge_info(from, to, self.class, info)
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

            alias remove_vertex! remove_vertex

            def remove_vertex(object)
                unless observer
                    return super
                end

                rel = self
                relations, relations_ids = [], []
                while rel
                    relations << rel
                    relations_ids << rel.class
                    rel = rel.parent
                end

                removed_relations = []
                in_neighbours(object).each { |parent| removed_relations << parent << object }
                out_neighbours(object).each { |child| removed_relations << object << child }

                removed_relations.each_slice(2) do |parent, child|
                    observer.removing_edge(parent, child, relations_ids)
                end
                relations.each { |rel| rel.remove_vertex!(object) }
                removed_relations.each_slice(2) do |parent, child|
                    observer.removed_edge(parent, child, relations_ids)
                end
                !removed_relations.empty?
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
                unless has_edge?(from, to)
                    return
                end

                rel = self
                relations, relations_ids = [], []
                while rel
                    relations << rel
                    relations_ids << rel.class
                    rel = rel.parent
                end

                observer&.removing_edge(from, to, relations_ids)
                for rel in relations
                    rel.remove_edge(from, to)
                end
                observer&.removed_edge(from, to, relations_ids)
            end

            # Compute the set of all graphs that are subsets of this one in the
            # subset hierarchy
            def recursive_subsets
                result = Set.new
                queue = subsets.to_a.dup
                until queue.empty?
                    g = queue.shift
                    result << g
                    queue.concat(g.subsets.to_a)
                end
                result
            end

            # True if this relation does not have a parent
            def root_relation?
                !parent
            end

            # True if this relation has no subset graph
            def leaf_relation?
                subsets.empty?
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

            # Tests the presence of an edge in this graph or in its supersets
            #
            # See #superset_of for a description of the parent mechanism
            def has_edge_in_hierarchy?(source, target)
                root_graph.has_edge?(source, target)
            end

            # Declare that +self+ is a superset of +relation+. Once this is done,
            # the system manages two constraints:
            # * new relations added with {#add_relation} are also added in self
            # * a relation can only exist in one subset of self
            #
            # One single graph can be the superset of multiple subgraphs (these are
            # stored in the {#subsets} attribute), but one graph can have only one
            # parent {#parent}.
            #
            # This operation can be called only if the new subset is empty (no
            # edges and no vertices)
            #
            # @param [Graph] relation the relation that should be added as a
            #   subset of self
            # @raise [ArgumentError] if 'relation' is not empty
            def superset_of(relation)
                unless relation.empty?
                    raise ArgumentError, "cannot pass a non-empty graph to #superset_of"
                end

                relation.parent = self
                subsets << relation
            end

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

            def each_parent_vertex(object, &block)
                Roby.warn_deprecated "#each_parent_vertex has been replaced by #each_in_neighbour"
                each_in_neighbour(object, &block)
            end

            def each_child_vertex(object, &block)
                Roby.warn_deprecated "#each_child_vertex has been replaced by #each_out_neighbour"
                each_out_neighbour(object, &block)
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

            # @deprecated use {#has_edge_in_hierarchy?}
            def linked_in_hierarchy?(source, target)
                Roby.warn_deprecated "#linked_in_hierarchy? is deprecated, use #has_edge_in_hierarchy? instead"
                has_edge_in_hierarchy?(source, target)
            end
        end
    end
end
