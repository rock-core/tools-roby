module Roby
    module Relations
        # Base support for relations. It is mixed in objects on which a
        # Relations::Space applies on, like Task for TaskStructure and EventGenerator
        # for EventStructure.
        #
        # See also the definition of Relations::Graph#add_relation and
        # Relations::Graph#remove_relation for the possibility to define hooks that
        # get called when a new edge involving +self+ as a vertex gets added and
        # removed 
        module DirectedRelationSupport
            include BGL::Vertex

            attr_reader :relation_graphs

            def relation_graph_for(rel)
                relation_graphs.fetch(rel)
            end

            # Enumerate all relations that are relevant for this plan object
            #
            # Unlike {#each_relation_graph}, which enumerate only the graphs
            # that include self, it enumerates all possible relations for self
            #
            # @yieldparam [Class<Graph>]
            def each_relation
                return enum_for(__method__) if !block_given?
                relation_graphs.each do |k, g|
                    yield(k) if k != g
                end
            end

            # Enumerate the relation graphs that include this vertex
            #
            # @yieldparam [Graph]
            def each_relation_graph
                return enum_for(__method__) if !block_given?
                relation_graphs.each do |k, g|
                    yield(g) if g.include?(self) && (k == g)
                end
            end

            # Enumerate the relation graphs that include this vertex and that
            # are subgraphs of no other graphs
            #
            # @yieldparam [Graph]
            def each_root_relation_graph
                return enum_for(__method__) if !block_given?
                each_relation_graph do |g|
                    yield(g) if g.root_relation?
                end
            end

            def generated_subgraph(relation = nil)
                super(relation_graphs[relation])
            end

            def root?(relation = nil)
                if relation
                    super(relation_graphs[relation])
                else
                    each_relation_graph.all? { |g| g.root?(self) }
                end
            end

            def leaf?(relation = nil)
                if relation
                    super(relation_graphs[relation])
                else
                    each_relation_graph.all? { |g| g.leaf?(self) }
                end
            end

            def child_object?(object, relation = nil)
                child_vertex?(object, relation_graphs[relation])
            end

            def parent_object?(object, relation = nil)
                parent_vertex?(object, relation_graphs[relation])
            end

            def related_object?(object, relation = nil)
                related_vertex?(object, relation_graphs[relation])
            end

            def each_parent_object(graph = nil)
                return enum_for(__method__, graph) if !block_given?
                each_parent_vertex(relation_graphs[graph]) do |parent|
                    yield(parent)
                end
            end

            def each_child_object(graph = nil)
                return enum_for(__method__, graph) if !block_given?
                each_child_vertex(relation_graphs[graph]) do |child|
                    yield(child)
                end
            end

            def sorted_relations
                Relations.all_relations.
                    find_all do |rel|
                        (rel = relation_graphs.fetch(rel, nil)) && rel.include?(self)
                    end
            end

            # Yields each relation this vertex is part of, starting with the most
            # specialized relations
            def each_relation_sorted
                # Remove from the set of relations the ones that are not leafs
                for rel in sorted_relations
                    yield(rel)
                end
            end

            # Removes +self+ from all the graphs it is included in.
            def clear_vertex
                for rel in sorted_relations
                    relation_graphs[rel].remove(self)
                end
            end
            alias :clear_relations :clear_vertex

            ##
            # :method: enum_relations => enumerator
            # Returns an Enumerator object for the set of relations this object is
            # included in. The same enumerator instance is always returned.
            cached_enum("relation", "relations", false)
            ##
            # :method: enum_parent_objects(relation) => enumerator
            # Returns an Enumerator object for the set of parents this object has
            # in +relation+. The same enumerator instance is always returned.
            cached_enum("parent_object", "parent_objects", true)
            ##
            # :method: enum_child_objects(relation) => enumerator
            # Returns an Enumerator object for the set of children this object has
            # in +relation+. The same enumerator instance is always returned.
            cached_enum("child_object", "child_objects", true)

            # The array of relations this object is part of
            def relations; enum_relations.to_a end

            # Computes and returns the set of objects related with this one (parent
            # or child). If +relation+ is given, enumerate only for this relation,
            # otherwise enumerate for all relations.  If +result+ is given, it is a
            # Set in which the related objects are added
            def related_objects(relation = nil, result = nil)
                result ||= Set.new
                if relation
                    result.merge(parent_objects(relation))
                    result.merge(child_objects(relation))
                else
                    each_relation { |rel| related_objects(rel, result) }
                end
                result
            end

            # Set of all parent objects in +relation+
            alias :parent_objects :enum_parent_objects
            # Set of all child object in +relation+
            alias :child_objects :enum_child_objects

            # Add a new child object in the +relation+ relation. This calls
            # * #adding_child_object on +self+ and #adding_parent_object on +child+
            #   just before the relation is added
            # * #added_child_object on +self+ and #added_parent_object on +child+
            #   just after
            def add_child_object(child, relation, info = nil)
                relation_graphs[relation].add_relation(self, child, info)
            end

            # Add a new parent object in the +relation+ relation
            # * #adding_child_object on +parent+ and #adding_parent_object on
            #   +self+ just before the relation is added
            # * #added_child_object on +parent+ and #added_child_object on +self+
            #   just after
            def add_parent_object(parent, relation, info = nil)
                relation_graphs[parent].add_child_object(self, relation, info)
            end

            # Remove all edges in which +self+ is the source and +child+ the
            # target. If +relation+ is given, it removes only the edge in that
            # relation graph.
            def remove_child_object(child, relation = nil)
                if !relation
                    for rel in sorted_relations
                        rel.remove_relation(self, child)
                    end
                else
                    relation_graphs[relation].remove_relation(self, child)
                end
            end

            # Remove all edges in which +self+ is the source. If +relation+
            # is given, it removes only the edges in that relation graph.
            def remove_children(relation = nil)
                if !relation
                    for rel in sorted_relations
                        remove_children(rel)
                    end
                    return
                end

                children = child_objects(relation).to_a
                for child in children
                    remove_child_object(child, relation)
                end
            end

            # Remove all edges in which +child+ is the source and +self+ the
            # target. If +relation+ is given, it removes only the edge in that
            # relation graph.
            def remove_parent_object(parent, relation = nil)
                parent.remove_child_object(self, relation)
            end

            # Remove all edges in which +self+ is the target. If +relation+
            # is given, it removes only the edges in that relation graph.
            def remove_parents(relation = nil)
                if !relation
                    for rel in sorted_relations
                        remove_parents(rel)
                    end
                    return
                end

                parents = parent_objects(relation).to_a
                for parent in parents
                    remove_parent_object(relation, parent)
                end
            end

            # Remove all relations that point to or come from +to+ If +to+ is nil,
            # it removes all edges in which +self+ is involved.
            #
            # If +relation+ is not nil, only edges of that relation graph are removed.
            def remove_relations(relation = nil)
                if !relation
                    for rel in sorted_relations
                        remove_relations(rel)
                    end
                    return
                end
                relation = relation_graphs[relation]
                return if !relation.include?(self)

                each_parent_object(relation) do |parent|
                    relation.remove_relation(parent, self)
                end

                each_child_object(relation) do |child|
                    relation.remove_relation(self, child)
                end
            end

            def [](object, graph)
                super(object, relation_graphs[graph])
            end

            def []=(object, relation, value)
                super(object, relation_graphs[relation], value)

                if respond_to?(:updated_edge_info)
                    updated_edge_info(object, relation, value)
                end
                if relation.respond_to?(:updated_info)
                    relation.updated_info(self, object, value)
                end
            end

            # Hook called before a new child is added to this object
            #
            # If an exception is raised, the child edge will not be removed
            #
            # As all Roby hook methods, one must call super when overloading
            #
            # @param [Object] child the child object
            # @param [Array<Relations::Graph>] relations the graphs in which an edge
            #   has been added
            # @param [Object] info the associated edge info that applies to
            #   relations.first
            def adding_child_object(child, relations, info)
                super if defined? super
                relations.each do |rel|
                    if name = rel.child_name
                        send("adding_#{rel.child_name}", child, info)
                        child.send("adding_#{rel.child_name}_parent", self, info)
                    end
                end
            end

            # Hook called after a new child has been added to this object
            #
            # As all Roby hook methods, one must call super when overloading
            #
            # @param [Object] child the child object
            # @param [Array<Relations::Graph>] relations the graphs in which an edge
            #   has been added
            # @param [Object] info the associated edge info that applies to
            #   relations.first
            def added_child_object(child, relations, info)
                super if defined? super
                relations.each do |rel|
                    if name = rel.child_name
                        send("added_#{rel.child_name}", child, info)
                        child.send("added_#{rel.child_name}_parent", self, info)
                    end
                end
            end

            # Hook called before a new child is added to this object
            #
            # If an exception is raised, the edge will not be removed
            #
            # As all Roby hook methods, one must call super when overloading
            #
            # @param [Object] child the child object
            # @param [Array<Relations::Graph>] relations the graphs in which an edge
            #   is being removed
            def removing_child_object(child, relations)
                super if defined? super
                relations.each do |rel|
                    if name = rel.child_name
                        send("removing_#{rel.child_name}", child)
                        child.send("removing_#{rel.child_name}_parent", self)
                    end
                end
            end

            # Hook called after a child has been removed from this object
            #
            # As all Roby hook methods, one must call super when overloading
            #
            # @param [Object] child the child object
            # @param [Array<Relations::Graph>] relations the graphs in which an edge
            #   has been removed
            def removed_child_object(child, relations)
                super if defined? super
                relations.each do |rel|
                    if name = rel.child_name
                        send("removed_#{rel.child_name}", child)
                        child.send("removed_#{rel.child_name}_parent", self)
                    end
                end
            end
        end
    end
end
