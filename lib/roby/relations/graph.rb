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
        class Graph < BGL::Graph
            # The relation name
            attr_reader   :name
            # The relation parent (if any). See #superset_of.
            attr_accessor :parent
            # The set of graphs that are directly children of self in the graph
            # hierarchy. They are subgraphs of self, but not all the existing
            # subgraphs of self. See {#recursive_subsets} to get all subsets
            attr_reader   :subsets
            # The set of all graphs that are known to be subgraphs of self
            attr_reader :recursive_subsets
            # The graph options as given to Relations::Space#relation
            attr_reader   :options

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
            def initialize(name, options = {})
                self.name = name
                @name    = name
                @options = options
                @subsets = Set.new
                @recursive_subsets = Set.new
                @distribute = options[:distribute]
                @dag     = options[:dag]
                @weak    = options[:weak]
                @strong  = options[:strong]
                @copy_on_replace = options[:copy_on_replace]
                @embeds_info = !options[:noinfo]

                if options[:subsets]
                    options[:subsets].each { |g| superset_of(g) }
                end
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

            def to_s; name end

            # True if this relation does not have a parent
            def root_relation?; !parent end

            # Remove +vertex+ from this graph. It removes all relations that
            # +vertex+ is part of, and calls the corresponding hooks
            def remove(vertex)
                return if !self.include?(vertex)
                vertex.remove_relations(self)
                super
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
                # Get the toplevel DAG in our relation hierarchy. We only test for the
                # DAG property on this one, as it is the union of all its children
                top_dag = nil
                new_relations = []
                rel     = self
                while rel
                    top_dag = rel if rel.dag?
                    if !rel.linked?(from, to)
                        new_relations << rel
                    end
                    rel = rel.parent
                end
                if top_dag && !top_dag.linked?(from, to) && top_dag.reachable?(to, from)
                    raise CycleFoundError, "cannot add a #{from} -> #{to} relation since it would create a cycle"
                end

                # Now check that we're not changing the edge info. This is ignored
                # if +self+ has the noinfo flag set.
                if linked?(from, to)
                    if !(old_info = from[to, self]).nil?
                        if old_info != info && !(info = merge_info(from, to, old_info, info))
                            raise ArgumentError, "trying to change edge information in #{self} for #{from} => #{to}: old was #{old_info} and new is #{info}"
                        end
                    end
                    from[to, self] = info
                    return
                end

                if !new_relations.empty?
                    if from.respond_to?(:adding_child_object)
                        from.adding_child_object(to, new_relations, info)
                    end
                    if to.respond_to?(:adding_parent_object)
                        to.adding_parent_object(from, new_relations, info)
                    end

                    for rel in new_relations
                        rel.__bgl_link(from, to, (info if self == rel))
                    end

                    if from.respond_to?(:added_child_object)
                        from.added_child_object(to, new_relations, info)
                    end
                    if to.respond_to?(:added_parent_object)
                        to.added_parent_object(from, new_relations, info)
                    end
                end
            end

            def updated_info(from, to, info)
                super if defined? super
            end

            def merge_info(from, to, old, new)
                super if defined? super
            end

            alias :__bgl_link :link

            # Unlike BGL::Graph#link, it is possible to "add" a link between two
            # objects that are already linked. Two cases
            #
            # * the 'info' parameter is identical, in which case nothing is done
            # * the 'info' parameter is different. #merge_info is called on the
            #   relation object. If it returns a non-nil object, then it is used
            #   as an updated info, otherwise, an error is generated.
            def link(from, to, info)
                if linked?(from, to)
                    old_info = from[to, self]
                    if info != old_info
                        if info = merge_info(from, to, old_info, info)
                            from[to, self] = info
                            return
                        else
                            raise ArgumentError, "trying to change edge information"
                        end
                    end
                    return
                end
                super(from, to, info)
            end

            # Remove the relation between +from+ and +to+, in this graph and in its
            # parent graphs as well.
            #
            # If +from+ or +to+ define the following hooks:
            #   removing_parent_object(parent, relations)
            #   removing_child_object(child, relations)
            #   removed_parent_object(parent, relations)
            #   removed_child_object(child, relations)
            #
            # then these hooks get respectively called once before and once after
            # having removed the relation, where +relations+ is the set of
            # Relations::Graph instances where the edge has been removed. It is always
            # <tt>[self, parent, parent.parent, ...]</tt> up to the root relation
            # which is a superset of +self+.
            def remove_relation(from, to)
                if !linked?(from, to)
                    return
                end

                rel = self
                relations = []
                while rel
                    relations << rel
                    rel = rel.parent
                end

                if from.respond_to?(:removing_child_object)
                    from.removing_child_object(to, relations)
                end
                if to.respond_to?(:removing_parent_object)
                    to.removing_parent_object(from, relations)
                end

                for rel in relations
                    rel.unlink(from, to)
                end

                if from.respond_to?(:removed_child_object)
                    from.removed_child_object(to, relations)
                end
                if to.respond_to?(:removed_parent_object)
                    to.removed_parent_object(from, relations)
                end
            end

            # Returns true if +relation+ is included in this relation (i.e. it is
            # either the same relation or one of its children)
            #
            # See also #superset_of
            def subset?(relation)
                self.eql?(relation) || subsets.any? { |subrel| subrel.subset?(relation) }
            end

            # Returns +true+ if there is an edge +source+ -> +target+ in this graph
            # or in one of its parents
            #
            # See #superset_of for a description of the parent mechanism
            def linked_in_hierarchy?(source, target)
                linked?(source, target) || (parent.linked?(source, target) if parent)
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
                    if linked_in_hierarchy?(source, target)
                        raise ArgumentError, "relation and self already share an edge"
                    end
                end

                relation.parent = self
                subsets << relation
                recompute_recursive_subsets

                # Copy the relations of the child into this graph
                relation.each_edge do |source, target, info|
                    source.add_child_object(target, self, info)
                end
            end

            # The Ruby module that gets included in graph objects
            attr_accessor :support

            # Recomputes the recursive_subsets attribute, and triggers the
            # recomputation on its parents as well
            def recompute_recursive_subsets
                @recursive_subsets = subsets.inject(Set.new) do |set, child|
                    set.merge(child.recursive_subsets)
                end
                if parent
                    parent.recompute_recursive_subsets
                end
            end
        end
    end
end

