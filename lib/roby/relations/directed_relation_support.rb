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

            alias :child_object?	    :child_vertex?
            alias :parent_object?	    :parent_vertex?
            alias :related_object?	    :related_vertex?
            alias :each_child_object    :each_child_vertex
            alias :each_parent_object   :each_parent_vertex

            def each_relation
                each_graph do |g|
                    yield(g) if g.kind_of?(Relations::Graph)
                end
            end

            def each_root_relation
                each_graph do |g|
                    yield(g) if g.kind_of?(Relations::Graph) && g.root_relation?
                end
            end

            def sorted_relations
                Relations.all_relations.
                    find_all { |rel| rel.include?(self) }
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
                    rel.remove(self)
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
                relation.add_relation(self, child, info)
            end

            # Add a new parent object in the +relation+ relation
            # * #adding_child_object on +parent+ and #adding_parent_object on
            #   +self+ just before the relation is added
            # * #added_child_object on +parent+ and #added_child_object on +self+
            #   just after
            def add_parent_object(parent, relation, info = nil)
                parent.add_child_object(self, relation, info)
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
                    relation.remove_relation(self, child)
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
                elsif !relation.include?(self)
                    return
                end

                each_parent_object(relation) do |parent|
                    relation.remove_relation(parent, self)
                end

                each_child_object(relation) do |child|
                    relation.remove_relation(self, child)
                end
            end

            def []=(object, relation, value)
                super

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
            end

            # Hook called after a child has been removed from this object
            #
            # As all Roby hook methods, one must call super when overloading
            #
            # @param [Object] child the child object
            # @param [Array<Relations::Graph>] relations the graphs in which an edge
            #   has been removed
            def removed_child_object(child, relations)
            end
        end
    end
end
