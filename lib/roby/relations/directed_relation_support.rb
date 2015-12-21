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
                    yield(g) if g.has_vertex?(self) && (k == g)
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

            def root?(relation = nil)
                if relation
                    relation_graphs[relation].root?(self)
                else
                    each_relation_graph.all? { |g| g.root?(self) }
                end
            end

            def leaf?(relation = nil)
                if relation
                    relation_graphs[relation].leaf?(self)
                else
                    each_relation_graph.all? { |g| g.leaf?(self) }
                end
            end

            def child_object?(object, relation = nil)
                relation_graphs[relation].has_edge?(self, object)
            end

            def parent_object?(object, relation = nil)
                relation_graphs[relation].has_edge?(object, self)
            end

            def related_object?(object, relation = nil)
                parent_object?(object, relation) || child_object?(object, relation)
            end

            def each_parent_object(graph, &block)
                relation_graphs[graph].each_in_neighbour(self, &block)
            end

            def each_in_neighbour(graph, &block)
                relation_graphs[graph].each_in_neighbour(self, &block)
            end

            def each_child_object(graph, &block)
                relation_graphs[graph].each_out_neighbour(self, &block)
            end

            def each_out_neighbour(graph, &block)
                relation_graphs[graph].each_out_neighbour(self, &block)
            end

            def sorted_relations
                Relations.all_relations.
                    find_all do |rel|
                        (rel = relation_graphs.fetch(rel, nil)) && rel.has_vertex?(self)
                    end
            end

            # Yields each relation this vertex is part of, starting with the most
            # specialized relations
            def each_relation_sorted(&block)
                sorted_relations.each(&block)
            end

            # Removes +self+ from all the graphs it is included in.
            def clear_vertex
                for rel in sorted_relations
                    relation_graphs[rel].remove_vertex(self)
                end
            end
            alias :clear_relations :clear_vertex

            def enum_relations
                Roby.warn_deprecated "DirectedRelationSupport#enum_relations is deprecated, use #each_relation instead"
                each_relation
            end

            # The array of relations this object is part of
            def relations; each_relation.to_a end

            # Computes and returns the set of objects related with this one (parent
            # or child). If +relation+ is given, enumerate only for this relation,
            # otherwise enumerate for all relations.  If +result+ is given, it is a
            # Set in which the related objects are added
            def related_objects(relation = nil, result = Set.new)
                if relation
                    result.merge(parent_objects(relation))
                    result.merge(child_objects(relation))
                else
                    each_root_relation_graph do |g|
                        result.merge(g.in_neighbours(self))
                        result.merge(g.out_neighbours(self))
                    end
                end
                result
            end

            def enum_parent_objects(relation)
                Roby.warn_deprecated "#enum_parent_objects is deprecated, use #parent_objects or #each_parent_object instead"
                parent_objects(relation)
            end

            def parent_objects(relation)
                relation_graphs[relation].in_neighbours(self)
            end

            def enum_child_objects(relation)
                Roby.warn_deprecated "#enum_child_objects is deprecated, use #parent_objects or #each_parent_object instead"
                child_objects(relation)
            end

            def child_objects(relation)
                relation_graphs[relation].out_neighbours(self)
            end

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
                return if !relation.has_vertex?(self)

                each_parent_object(relation).to_a.each do |parent|
                    relation.remove_relation(parent, self)
                end

                each_child_object(relation).to_a.each do |child|
                    relation.remove_relation(self, child)
                end
            end

            def [](object, graph)
                relation_graphs[graph].edge_info(self, object)
            end

            def []=(object, relation, value)
                relation_graphs[relation].set_edge_info(self, object, value)
            end
        end
    end
end
