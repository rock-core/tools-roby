module Roby
    module Queries
    # Predicate that matches characteristics on a plan object
    class PlanObjectMatcher < MatcherBase
        # @api private
        #
        # A set of models that should be provided by the object
        #
        # @return [Array<Class>]
	attr_reader :model
        
        # @api private
        #
        # Set of owners that the object should have
        #
        # @return [Array<DRobyID>]
        attr_reader :owners

        # @api private
        #
        # Set of predicates that should be true on the object, and for which
        # the index maintains a set of objects for which it is true
        #
        # @return [Array<Symbol>]
        attr_reader :indexed_predicates
       
        # @api private
        #
        # Set of predicates that should be false on the object, and for which
        # the index maintains a set of objects for which it is true
        #
        # @return [Array<Symbol>]
        attr_reader :indexed_neg_predicates

        # @api private
        #
        # Per-relation list of in-edges that the matched object is expected to have
        #
        # @return [Hash]
        attr_reader :parents

        # @api private
        #
        # Per relation list of out-edges that the matched object is expected to have
        #
        # @return [Hash]
        attr_reader :children

        # Initializes an empty TaskMatcher object
	def initialize
            @model                = Array.new
	    @predicates           = Set.new
	    @neg_predicates       = Set.new
	    @indexed_predicates     = Set.new
	    @indexed_neg_predicates = Set.new
	    @owners               = Array.new
            @parents              = Hash.new { |h, k| h[k] = Array.new }
            @children             = Hash.new { |h, k| h[k] = Array.new }
	end

        # Filters on ownership
        #
        # Matches if the object is owned by the listed peers.
        #
        # Use #self_owned to match if it is owned by the local plan manager.
	def owned_by(*ids)
	    @owners |= ids
	    self
	end

        # Filters locally-owned tasks
        #
        # Matches if the object is owned by the local plan manager.
	def self_owned
            predicates << :self_owned?
	    self
	end

        # Filters out locally-owned tasks
        #
        # Matches if the object is owned by the local plan manager.
        def not_self_owned
            neg_predicates << :self_owned?
	    self
        end

	# Filters on the task model
        #
        # Will match if the task is an instance of +model+ or one of its
        # subclasses.
	def with_model(model)
	    @model = Array(model)
	    self
	end

	class << self
            # @api private
            def match_predicate(name, positive_index = nil, negative_index = nil)
                method_name = name.to_s.gsub(/\?$/, '')
                if Index::PREDICATES.include?(name)
                    positive_index ||= [["#{name}"], []]
                    negative_index ||= [[], ["#{name}"]]
                end
                positive_index ||= [[], []]
                negative_index ||= [[], []]
                class_eval <<-EOD, __FILE__, __LINE__+1
                def #{method_name}
                    if neg_predicates.include?(:#{name})
                        raise ArgumentError, "trying to match (#{name} & !#{name})"
                    end
                    predicates << :#{name}
                    #{if !positive_index[0].empty? then ["indexed_predicates", *positive_index[0]].join(" << :") end}
                    #{if !positive_index[1].empty? then ["indexed_neg_predicates", *positive_index[1]].join(" << :") end}
                    self
                end
                def not_#{method_name}
                    if predicates.include?(:#{name})
                        raise ArgumentError, "trying to match (#{name} & !#{name})"
                    end
                    neg_predicates << :#{name}
                    #{if !negative_index[0].empty? then ["indexed_predicates", *negative_index[0]].join(" << :") end}
                    #{if !negative_index[1].empty? then ["indexed_neg_predicates", *negative_index[1]].join(" << :") end}
                    self
                end
                EOD
                declare_class_methods(method_name, "not_#{method_name}")
            end
	end

        ##
        # :method: executable
        #
        # Matches if the object is executable
        #
        # See also #not_executable, PlanObject#executable?

        ##
        # :method: not_executable
        #
        # Matches if the object is not executable
        #
        # See also #executable, PlanObject#executable?

	match_predicates :executable?

        declare_class_methods :with_model, :owned_by, :self_owned

        # Helper method for #with_child and #with_parent
        def handle_parent_child_arguments(other_query, relation, relation_options) # :nodoc:
            return relation, [other_query.match, relation_options]
        end

        # Filters based on the object's children
        #
        # Matches if this object has at least one child which matches +query+.
        #
        # If +relation+ is given, then only the children in this relation are
        # considered. Moreover, relation options can be used to restrict the
        # search even more.
        #
        # Examples:
        #
        #   parent.depends_on(child)
        #   TaskMatcher.new.
        #       with_child(TaskMatcher.new.pending) === parent # => true
        #   TaskMatcher.new.
        #       with_child(TaskMatcher.new.pending, Roby::TaskStructure::Dependency) === parent # => true
        #   TaskMatcher.new.
        #       with_child(TaskMatcher.new.pending, Roby::TaskStructure::PlannedBy) === parent # => false
        #
        #   TaskMatcher.new.
        #       with_child(TaskMatcher.new.pending,
        #                  Roby::TaskStructure::Dependency,
        #                  roles: ["trajectory_following"]) === parent # => false
        #   parent.depends_on child, role: "trajectory_following"
        #   TaskMatcher.new.
        #       with_child(TaskMatcher.new.pending,
        #                  Roby::TaskStructure::Dependency,
        #                  roles: ["trajectory_following"]) === parent # => true
        #
        def with_child(other_query, relation = nil, relation_options = nil)
            relation, spec = handle_parent_child_arguments(other_query, relation, relation_options)
            @children[relation] << spec
            self
        end

        # Filters based on the object's parents
        #
        # Matches if this object has at least one parent which matches +query+.
        #
        # If +relation+ is given, then only the parents in this relation are
        # considered. Moreover, relation options can be used to restrict the
        # search even more.
        #
        # See examples for #with_child
        def with_parent(other_query, relation = nil, relation_options = nil)
            relation, spec = handle_parent_child_arguments(other_query, relation, relation_options)
            @parents[relation] << spec
            self
        end

        # Helper method for handling parent/child matches in #===
        def handle_parent_child_match(object, match_spec) # :nodoc:
            relation, matchers = *match_spec
            return false if !relation && object.relations.empty?
            for match_spec in matchers
                m, relation_options = *match_spec
                if relation
                    if !yield(relation, m, relation_options)
                        return false 
                    end
                else
                    result = object.relations.any? do |rel|
                        yield(rel, m, relation_options)
                    end
                    return false if !result
                end
            end
            true
        end

        # Returns true if filtering with this TaskMatcher using #=== is
        # equivalent to calling #filter() using a Index. This is used to
        # avoid an explicit O(N) filtering step after filter() has been called
        def indexed_query?
            @children.empty? && @parents.empty? &&
                Index::PREDICATES.superset?(predicates) &&
                Index::PREDICATES.superset?(neg_predicates)
        end


        # Tests whether the given object matches this predicate
        #
        # @param [PlanObject] object the object to match
        # @return [Boolean]
        def ===(object)
	    if !model.empty?
		return unless object.fullfills?(model)
	    end

            for parent_spec in @parents
                result = handle_parent_child_match(object, parent_spec) do |relation, m, relation_options|
                    object.each_parent_object(relation).
                        any? { |parent| m === parent && (!relation_options || relation_options === parent[object, relation]) }
                end
                return false if !result
            end

            for child_spec in @children
                result = handle_parent_child_match(object, child_spec) do |relation, m, relation_options|
                    object.each_child_object(relation).
                        any? { |child| m === child && (!relation_options || relation_options === object[child, relation]) }
                end
                return false if !result
            end

	    for pred in predicates
		return false if !object.send(pred)
	    end
	    for pred in neg_predicates
		return false if object.send(pred)
	    end

	    return false if !owners.empty? && !(object.owners - owners).empty?
            true
        end

        # Filters the tasks in +initial_set+ by using the information in
        # +index+, and returns the result. The resulting set must
        # include all tasks in +initial_set+ which match with #===, but can
        # include tasks which do not match #===
        #
        # @param [Set] initial_set
        # @param [Index] index
        # @return [Set]
	def filter(initial_set, index)
            for m in model
                initial_set = initial_set.intersection(index.by_model[m])
            end

            for o in owners
                if candidates = index.by_owner[o]
                    initial_set = initial_set.intersection(candidates)
                else
                    return Set.new
                end
            end

	    for pred in indexed_predicates
		initial_set = initial_set.intersection(index.by_predicate[pred])
	    end

	    for pred in indexed_neg_predicates
		initial_set = initial_set.difference(index.by_predicate[pred])
	    end

	    initial_set
	end
    end
    end
end

