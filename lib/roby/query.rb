module Roby
    class Task
        # Returns a TaskMatcher object
	def self.match(*args)
	    matcher = TaskMatcher.new
            if args.empty? && self != Task
                matcher.which_fullfills(self)
            else
                matcher.which_fullfills(*args)
            end
            matcher
	end
    end

    # This class represents a predicate which can be used to filter tasks. To
    # filter plan-related properties, use Query.
    #
    # A TaskMatcher object is a AND combination of various tests against tasks.
    #
    # For instance, if one does
    #
    #   matcher = TaskMatcher.new.which_fullfills(Tasks::Simple).pending
    #
    # Then
    #  
    #   matcher === task
    #
    # will return true if +task+ is an instance of the Tasks::Simple model and
    # is pending (not started yet), and false if one of these two
    # characteristics is not true.
    class TaskMatcher
	attr_reader :model, :arguments
	attr_reader :predicates, :neg_predicates, :owners

        attr_reader :indexed_predicates, :indexed_neg_predicates

        # Initializes an empty TaskMatcher object
	def initialize
	    @predicates           = ValueSet.new
	    @neg_predicates       = ValueSet.new
	    @indexed_predicates     = ValueSet.new
	    @indexed_neg_predicates = ValueSet.new
	    @owners               = Array.new
	    @interruptible	  = nil
            @parents              = Hash.new { |h, k| h[k] = Array.new }
            @children             = Hash.new { |h, k| h[k] = Array.new }
	end

	# Filters on task model and arguments
        #
        # Will match if the task is an instance of +model+ or one of its
        # subclasses, and if parts of its arguments are the ones provided. Set
        # +arguments+ to nil if you don't want to filter on arguments.
	def which_fullfills(model, arguments = nil)
	    with_model(model)
            if arguments
                with_model_arguments(arguments)
            end
            self
	end

	# Filters on the task model
        #
        # Will match if the task is an instance of +model+ or one of its
        # subclasses.
	def with_model(model)
	    @model = model
	    self
	end
	
	# Filters on the arguments that are declared in the model
        #
        # Will match if the task arguments for which there is a value in
        # +arguments+ are set to that very value, only looking at arguments that
        # are defined in the model set by #with_model.
        #
        # See also #with_arguments
        #
        # Example:
        #
        #   class TaskModel < Roby::Task
        #     argument :a
        #     argument :b
        #   end
        #   task = TaskModel.new(:a => 10, :b => 20)
        #
        #   # Matches on :a, :b is ignored altogether
        #   TaskMatcher.new.
        #       with_model(TaskModel).
        #       with_model_arguments(:a => 10) === task # => true
        #   # Looks for both :a and :b
        #   TaskMatcher.new.
        #       with_model(TaskModel).
        #       with_model_arguments(:a => 10, :b => 30) === task # => false
        #   # Matches on :a, :c is ignored as it is not an argument of +TaskModel+
        #   TaskMatcher.new.
        #       with_model(TaskModel).
        #       with_model_arguments(:a => 10, :c => 30) === task # => true
        #
        # In general, one would use #which_fullfills, which sets both the model
        # and the model arguments
	def with_model_arguments(arguments)
	    if !model
		raise ArgumentError, "set model first"
	    end
            if model.respond_to?(:to_ary)
                valid_arguments = model.inject(Set.new) { |args, m| args | m.arguments.to_set }
            else
                valid_arguments = model.arguments
            end
	    with_arguments(arguments.slice(*model.arguments))
	    self
	end

	# Filters on the arguments that are declared in the model
        #
        # Will match if the task arguments for which there is a value in
        # +arguments+ are set to that very value. Unlike #with_model_arguments,
        # all values set in +arguments+ are considered.
        #
        # See also #with_model_arguments
        #
        # Example:
        #
        #   class TaskModel < Roby::Task
        #     argument :a
        #     argument :b
        #   end
        #   task = TaskModel.new(:a => 10, :b => 20)
        #
        #   # Matches on :a, :b is ignored altogether
        #   TaskMatcher.new.
        #       with_arguments(:a => 10) === task # => true
        #   # Looks for both :a and :b
        #   TaskMatcher.new.
        #       with_arguments(:a => 10, :b => 30) === task # => false
        #   # Looks for both :a and :c, even though :c is not declared in TaskModel
        #   TaskMatcher.new.
        #       with_arguments(:a => 10, :c => 30) === task # => false
	def with_arguments(arguments)
	    @arguments ||= Hash.new
	    self.arguments.merge!(arguments) do |k, old, new| 
		if old != new
		    raise ArgumentError, "a constraint has already been set on the #{k} argument" 
		end
		old
	    end
	    self
	end

        # Filters on ownership
        #
        # Matches if the task is owned by the listed peers.
        #
        # Use #self_owned to match if it is owned by the local plan manager.
	def owned_by(*ids)
	    @owners |= ids
	    self
	end

        # Filters locally-owned tasks
        #
        # Matches if the task is owned by the local plan manager.
	def self_owned
	    owned_by(Roby::Distributed)
	    self
	end

	class << self
	    def declare_class_methods(*names) # :nodoc:
		names.each do |name|
		    raise "no instance method #{name} on TaskMatcher" unless TaskMatcher.method_defined?(name)
		    TaskMatcher.singleton_class.send(:define_method, name) do |*args|
			TaskMatcher.new.send(name, *args)
		    end
		end
	    end

            def match_predicate(name, positive_index = nil, negative_index = nil)
                if TaskIndex::STATE_PREDICATES.include?(:"#{name}?")
                    positive_index ||= [[":#{name}?"], []]
                    negative_index ||= [[], [":#{name}?"]]
                end
                positive_index ||= [[], []]
                negative_index ||= [[], []]
                class_eval <<-EOD, __FILE__, __LINE__+1
                def #{name}
                    if neg_predicates.include?(:#{name}?)
                        raise ArgumentError, "trying to match (#{name}? & !#{name}?)"
                    end
                    predicates << :#{name}?
                    #{if !positive_index[0].empty? then ["indexed_predicates", *positive_index[0]].join(" << ") end}
                    #{if !positive_index[1].empty? then ["indexed_neg_predicates", *positive_index[1]].join(" << ") end}
                    self
                end
                def not_#{name}
                    if predicates.include?(:#{name}?)
                        raise ArgumentError, "trying to match (#{name}? & !#{name}?)"
                    end
                    neg_predicates << :#{name}?
                    #{if !negative_index[0].empty? then ["indexed_predicates", *negative_index[0]].join(" << ") end}
                    #{if !negative_index[1].empty? then ["indexed_neg_predicates", *negative_index[1]].join(" << ") end}
                    self
                end
                EOD
                declare_class_methods(name, "not_#{name}")
            end

            # For each name in +names+, define a #name and a #not_name method.
            # If the first is called, the matcher will match only tasks whose
            # #name? method returns true.  If the second is called, the
            # opposite will be done.
	    def match_predicates(*names)
		names.each do |name|
                    match_predicate(name)
		end
	    end
	end

        ##
        # :method: fully_instanciated
        #
        # Matches if the task is fully instanciated
        #
        # See also #partially_instanciated, Task#fully_instanciated?

        ##
        # :method: partially_instanciated
        #
        # Matches if the task is partially instanciated
        #
        # See also #fully_instanciated, Task#partially_instanciated?

        ##
        # :method: not_abstract
        #
        # Matches if the task is not abstract
        #
        # See also #abstract, Task#abstract?

        ##
        # :method: abstract
        #
        # Matches if the task is abstract
        #
        # See also #not_abstract, Task#abstract?

        ##
        # :method: not_abstract
        #
        # Matches if the task is not abstract
        #
        # See also #abstract, Task#abstract?

        ##
        # :method: executable
        #
        # Matches if the task is executable
        #
        # See also #not_executable, Task#executable?

        ##
        # :method: not_executable
        #
        # Matches if the task is not executable
        #
        # See also #executable, Task#executable?

        ##
        # :method: pending
        #
        # Matches if the task is pending
        #
        # See also #not_pending, Task#pending?

        ##
        # :method: not_pending
        #
        # Matches if the task is not pending
        #
        # See also #pending, Task#pending?

        ##
        # :method: running
        #
        # Matches if the task is running
        #
        # See also #not_running, Task#running?

        ##
        # :method: not_running
        #
        # Matches if the task is not running
        #
        # See also #running, Task#running?

        ##
        # :method: finished
        #
        # Matches if the task is finished
        #
        # See also #not_finished, Task#finished?

        ##
        # :method: not_finished
        #
        # Matches if the task is not finished
        #
        # See also #finished, Task#finished?

        ##
        # :method: success
        #
        # Matches if the task is success
        #
        # See also #not_success, Task#success?

        ##
        # :method: not_success
        #
        # Matches if the task is not success
        #
        # See also #success, Task#success?

        ##
        # :method: failed
        #
        # Matches if the task is failed
        #
        # See also #not_failed, Task#failed?

        ##
        # :method: not_failed
        #
        # Matches if the task is not failed
        #
        # See also #failed, Task#failed?

        ##
        # :method: interruptible
        #
        # Matches if the task is interruptible
        #
        # See also #not_interruptible, Task#interruptible?

        ##
        # :method: not_interruptible
        #
        # Matches if the task is not interruptible
        #
        # See also #interruptible, Task#interruptible?

        ##
        # :method: finishing
        #
        # Matches if the task is finishing
        #
        # See also #not_finishing, Task#finishing?

        ##
        # :method: not_finishing
        #
        # Matches if the task is not finishing
        #
        # See also #finishing, Task#finishing?

	match_predicates :executable, :abstract, :partially_instanciated, :fully_instanciated,
	    :pending, :running, :finished, :success, :failed, :interruptible

        # Finishing tasks are also running task, use the index on 'running'
        match_predicate :finishing, [[":running?"], []]

        # Reusable tasks must be neither finishing nor finished
        match_predicate :reusable, [[], [:finished]]


        # Helper method for #with_child and #with_parent
        def handle_parent_child_arguments(other_query, relation, relation_options) # :nodoc:
            if !other_query.kind_of?(TaskMatcher) && !other_query.kind_of?(Task)
                if relation.kind_of?(Hash)
                    arguments = relation
                    relation         = (arguments.delete(:relation) || arguments.delete('relation'))
                    relation_options = (arguments.delete(:relation_options) || arguments.delete('relation_options'))
                else
                    arguments = Hash.new
                end
                other_query = TaskMatcher.which_fullfills(other_query, arguments)
            end
            return relation, [other_query, relation_options]
        end

        # Filters based on the task's children
        #
        # Matches if this task has at least one child which matches +query+.
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
        #                  :roles => ["trajectory_following"]) === parent # => false
        #   parent.depends_on child, :role => "trajectory_following"
        #   TaskMatcher.new.
        #       with_child(TaskMatcher.new.pending,
        #                  Roby::TaskStructure::Dependency,
        #                  :roles => ["trajectory_following"]) === parent # => true
        #
        def with_child(other_query, relation = nil, relation_options = nil)
            relation, spec = handle_parent_child_arguments(other_query, relation, relation_options)
            @children[relation] << spec
            self
        end

        # Filters based on the task's parents
        #
        # Matches if this task has at least one parent which matches +query+.
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
        def handle_parent_child_match(task, match_spec) # :nodoc:
            relation, matchers = *match_spec
            return false if !relation && task.relations.empty?
            for match_spec in matchers
                m, relation_options = *match_spec
                if relation
                    if !yield(relation, m, relation_options)
                        return false 
                    end
                else
                    result = task.relations.any? do |rel|
                        yield(rel, m, relation_options)
                    end
                    return false if !result
                end
            end
            true
        end

        # True if +task+ matches all the criteria defined on this object.
	def ===(task)
	    return unless task.kind_of?(Roby::Task)
	    if model
		return unless task.fullfills?(model)
	    end
	    if arguments
		return unless task.arguments.slice(*arguments.keys) == arguments
	    end

            for parent_spec in @parents
                result = handle_parent_child_match(task, parent_spec) do |relation, m, relation_options|
                    task.enum_parent_objects(relation).
                        any? { |parent| m === parent && (!relation_options || relation_options === parent[task, relation]) }
                end
                return false if !result
            end

            for child_spec in @children
                result = handle_parent_child_match(task, child_spec) do |relation, m, relation_options|
                    task.enum_child_objects(relation).
                        any? { |child| m === child && (!relation_options || relation_options === task[child, relation]) }
                end
                return false if !result
            end

	    for pred in predicates
		return false if !task.send(pred)
	    end
	    for pred in neg_predicates
		return false if task.send(pred)
	    end

	    return false if !owners.empty? && !(task.owners - owners).empty?
	    true
	end

        # Returns true if filtering with this TaskMatcher using #=== is
        # equivalent to calling #filter() using a TaskIndex. This is used to
        # avoid an explicit O(N) filtering step after filter() has been called
        def indexed_query?
            (!arguments || arguments.empty?) && @children.empty? && @parents.empty? &&
                TaskIndex::STATE_PREDICATES.include_all?(predicates) &&
                TaskIndex::STATE_PREDICATES.include_all?(neg_predicates)
        end

        # Filters the tasks in +initial_set+ by using the information in
        # +task_index+, and returns the result. The resulting set must
        # include all tasks in +initial_set+ which match with #===, but can
        # include tasks which do not match #===
	def filter(initial_set, task_index)
	    if model
                if model.respond_to?(:to_ary)
                    for m in model
                        initial_set.intersection!(task_index.by_model[m])
                    end
                else
                    initial_set.intersection!(task_index.by_model[model])
                end
	    end

	    if !owners.empty?
		for o in owners
		    if candidates = task_index.by_owner[o]
			initial_set.intersection!(candidates)
		    else
			return ValueSet.new
		    end
		end
	    end

	    for pred in indexed_predicates
		initial_set.intersection!(task_index.by_state[pred])
	    end

	    for pred in indexed_neg_predicates
		initial_set.difference!(task_index.by_state[pred])
	    end

	    initial_set
	end

        # Enumerates all tasks of +plan+ which match this TaskMatcher object
        #
        # It is O(N). You should prefer use Query which uses the plan's task
        # indexes, thus leading to O(1) in simple cases.
	def each(plan, &block)
            plan.each_task do |t|
                yield(t) if self === t
            end
	    self
	end

	# Define singleton classes. For instance, calling TaskMatcher.which_fullfills is equivalent
	# to TaskMatcher.new.which_fullfills
	declare_class_methods :which_fullfills, 
	    :with_model, :with_arguments, 
	    :owned_by, :self_owned

        # Negates this predicate
        #
        # The returned task matcher will yield tasks that are *not* matched by
        # +self+
	def negate; NegateTaskMatcher.new(self) end
        # AND-combination of two predicates 
        #
        # The returned task matcher will yield tasks that are matched by both
        # predicates.
	def &(other); AndTaskMatcher.new(self, other) end
        # OR-combination of two predicates 
        #
        # The returned task matcher will yield tasks that match either one
        # predicate or the other.
	def |(other); OrTaskMatcher.new(self, other) end
    end

    # A query is a TaskMatcher that applies on a plan. It should, in general, be
    # preferred to TaskMatcher as it uses task indexes to be more efficient.
    #
    # Queries cache their result. I.e. once #each has been called to get the
    # query results, the query will always return the same results until #reset
    # has been called.
    class Query < TaskMatcher
        # The plan this query acts on
	attr_reader :plan

        # Create a query object on the given plan
	def initialize(plan)
            @scope = :global
	    @plan = plan
	    super()
	    @plan_predicates = Array.new
	    @neg_plan_predicates = Array.new
	end

        # Search scope for queries on transactions. If equal to :local, the
        # query will apply only on the scope of the searched transaction,
        # otherwise it applies on a virtual plan that is the result of the
        # transaction stack being applied.
        #
        # The default is :global.
        #
        # See #local_scope and #global_scope
        attr_reader :scope

        # Changes the scope of this query. See #scope.
        def local_scope; @scope = :local end
        # Changes the scope of this query. See #scope.
        def global_scope; @scope = :global end

        # Changes the plan this query works on. This calls #reset (obviously)
        def plan=(new_plan)
            reset
            @plan = new_plan
        end

        # The set of tasks which match in plan. This is a cached value, so use
        # #reset to actually recompute this set.
	def result_set
	    @result_set ||= plan.query_result_set(self)
	end

        # Overload of TaskMatcher#filter
	def filter(initial_set, task_index)
            result = super

            if plan_predicates.include?(:mission?)
                result.intersection!(plan.missions)
            elsif neg_plan_predicates.include?(:mission?)
                result.difference!(plan.missions)
            end

            if plan_predicates.include?(:permanent?)
                result.intersection!(plan.permanent_tasks)
            elsif neg_plan_predicates.include?(:permanent?)
                result.difference!(plan.permanent_tasks)
            end

            result
        end

        # Reinitializes the cached query result.
        #
        # Queries cache their result, i.e. #each will always return the same
        # task set. #reset makes sure that the next call to #each will return
        # the same value.
	def reset
	    @result_set = nil
	    self
	end

        # The set of predicates of Plan which must return true for #=== to
        # return true
	attr_reader :plan_predicates
        # The set of predicates of Plan which must return false for #=== to
        # return true.
	attr_reader :neg_plan_predicates

	class << self
            # For each name in +names+, define the #name and #not_name methods
            # on Query objects. When one of these methods is called on a Query
            # object, plan.name?(task) must return true (resp. false) for the
            # task to match.
	    def match_plan_predicates(*names)
		names.each do |name|
		    class_eval <<-EOD, __FILE__, __LINE__+1
		    def #{name}
			if neg_plan_predicates.include?(:#{name}?)
			    raise ArgumentError, "trying to match (#{name}? & !#{name}?)"
		        end
			plan_predicates << :#{name}?
			self
		    end
		    def not_#{name}
			if plan_predicates.include?(:#{name}?)
			    raise ArgumentError, "trying to match (#{name}? & !#{name}?)"
		        end
			neg_plan_predicates << :#{name}?
			self
		    end
		    EOD
		end
	    end
	end

        ##
        # :method: mission
        #
        # Filters missions
        #
        # Matches tasks in plan that are missions

        ##
        # :method: not_mission
        #
        # Filters out missions
        #
        # Matches tasks in plan that are not missions

        ##
        # :method: permanent
        #
        # Filters permanent tasks
        #
        # Matches tasks in plan that are declared as permanent tasks.
        #
        # See Plan#add_permanent

        ##
        # :method: not_permanent
        #
        # Filters out permanent tasks
        #
        # Matches tasks in plan that are not declared as permanent tasks
        #
        # See Plan#add_permanent

	match_plan_predicates :mission, :permanent
	
        # Filters tasks which have no parents in the query itself.
        #
        # Will filter out tasks which have parents in +relation+ that are
        # included in the query result.
	def roots(relation)
	    @result_set = plan.query_roots(result_set, relation)
	    self
	end

        # True if +task+ matches the query. Call #result_set to have the set of
        # tasks which match in the given plan.
	def ===(task)
	    return unless super

	    for pred in plan_predicates
		return unless plan.send(pred, task)
	    end
	    for neg_pred in neg_plan_predicates
		return if plan.send(neg_pred, task)
	    end
	    true
	end

        # Iterates on all the tasks in the given plan which match the query
        #
        # This set is cached, i.e. #each will yield the same task set until
        # #reset is called.
	def each(&block)
	    plan.query_each(result_set, &block)
	    self
	end
	include Enumerable
    end

    # This task combines multiple task matching predicates through a OR boolean
    # operator. I.e. it will match if any of the underlying predicates match.
    class OrTaskMatcher < TaskMatcher
        # Create a new OrTaskMatcher object combining the given predicates.
	def initialize(*ops)
	    @ops = ops 
	    super()
	end

        # Overload of TaskMatcher#filter
	def filter(task_set, task_index)
	    result = ValueSet.new
	    for child in @ops
		result.merge child.filter(task_set, task_index)
	    end
	    result
	end

        # Add a new predicate to the combination
	def <<(op); @ops << op end

        # Overload of TaskMatcher#===
	def ===(task)
	    return unless @ops.any? { |op| op === task }
	    super
	end
    end

    # Negate a given task-matching predicate
    #
    # This matcher will match if the underlying predicate does not match.
    class NegateTaskMatcher < TaskMatcher
        # Create a new TaskMatcher which matches if and only if +op+ does not
	def initialize(op)
	    @op = op
	    super()
       	end

        # Filters as much as non-matching tasks as possible out of +task_set+,
        # based on the information in +task_index+
	def filter(initial_set, task_index)
	    # WARNING: the value returned by filter is a SUPERSET of the
	    # possible values for the query. Therefore, the result of
	    # NegateTaskMatcher#filter is NOT
	    #
	    #   initial_set - @op.filter(...)
	    initial_set
	end

        # True if the task matches at least one of the underlying predicates
	def ===(task)
	    return if @op === task
	    super
	end
    end

    # This task combines multiple task matching predicates through a AND boolean
    # operator. I.e. it will match if none of the underlying predicates match.
    class AndTaskMatcher < TaskMatcher
        # Create a new AndTaskMatcher object combining the given predicates.
	def initialize(*ops)
	    @ops = ops 
	    super()
	end

        # Filters as much as non-matching tasks as possible out of +task_set+,
        # based on the information in +task_index+
	def filter(task_set, task_index)
	    result = task_set
	    for child in @ops
		result &= child.filter(task_set, task_index)
	    end
	    result
	end

        # Add a new predicate to the combination
	def <<(op); @ops << op end
        # True if the task matches at least one of the underlying predicates
	def ===(task)
	    return unless @ops.all? { |op| op === task }
	    super
	end
    end

    class Plan
        # Returns a Query object that applies on this plan.
        #
        # This is equivalent to
        #
        #   Roby::Query.new(self)
        #
        # Additionally, the +model+ and +args+ options are passed to
        # Query#which_fullfills. For example:
        #
        #   plan.find_tasks(Tasks::SimpleTask, :id => 20)
        #
        # is equivalent to
        #
        #   Roby::Query.new(self).which_fullfills(Tasks::SimpleTask, :id => 20)
        #
        # The returned query is applied on the global scope by default. This
        # means that, if it is applied on a transaction, it will match tasks
        # that are in the underlying plans but not yet in the transaction,
        # import the matches in the transaction and return the new proxies.
        #
        # See #find_local_tasks for a local query.
	def find_tasks(model = nil, args = nil)
	    q = Query.new(self)
	    if model || args
		q.which_fullfills(model, args)
	    end
	    q
	end

        # Starts a local query on this plan.
        #
        # Unlike #find_tasks, when applied on a transaction, it will only match
        # tasks that are already in the transaction.
        #
        # See #find_global_tasks for a local query.
        def find_local_tasks(*args, &block)
            query = find_tasks(*args, &block)
            query.local_scope
            query
        end

	# Called by TaskMatcher#result_set and Query#result_set to get the set
	# of tasks matching +matcher+
	def query_result_set(matcher) # :nodoc:
            filtered = matcher.filter(known_tasks.dup, task_index)

            if matcher.indexed_query?
                filtered
            else
                result = ValueSet.new
                for task in filtered
                    result << task if matcher === task
                end
                result
            end
	end

	# Called by TaskMatcher#each and Query#each to return the result of
	# this query on +self+
	def query_each(result_set, &block) # :nodoc:
	    for task in result_set
		yield(task)
	    end
	end

	# Given the result set of +query+, returns the subset of tasks which
	# have no parent in +query+
	def query_roots(result_set, relation) # :nodoc:
	    children = ValueSet.new
	    found    = ValueSet.new
	    for task in result_set
		next if children.include?(task)
		task_children = task.generated_subgraph(relation)
		found -= task_children
		children.merge(task_children)
		found << task
	    end
	    found
	end
    end

    class Transaction
	# Returns two sets of tasks, [plan, transaction]. The union of the two
	# is the component that would be returned by
	# +relation.generated_subgraphs(*seeds)+ if the transaction was
	# committed
        #
        # This is an internal method used by queries
	def merged_generated_subgraphs(relation, plan_seeds, transaction_seeds)
	    plan_set        = ValueSet.new
	    transaction_set = ValueSet.new
	    plan_seeds	      = plan_seeds.to_value_set
	    transaction_seeds = transaction_seeds.to_value_set

	    loop do
		old_transaction_set = transaction_set.dup
		transaction_set.merge(transaction_seeds)
		for new_set in relation.generated_subgraphs(transaction_seeds, false)
		    transaction_set.merge(new_set)
		end

		if old_transaction_set.size != transaction_set.size
		    for o in (transaction_set - old_transaction_set)
			if o.respond_to?(:__getobj__)
			    o.__getobj__.each_child_object(relation) do |child|
				plan_seeds << child unless self[child, false]
			    end
			end
		    end
		end
		transaction_seeds.clear

		plan_set.merge(plan_seeds)
		plan_seeds.each do |seed|
		    relation.each_dfs(seed, BGL::Graph::TREE) do |_, dest, _, kind|
			next if plan_set.include?(dest)
			if self[dest, false]
			    proxy = wrap(dest, false)
			    unless transaction_set.include?(proxy)
				transaction_seeds << proxy
			    end
			    relation.prune # transaction branches must be developed inside the transaction
			else
			    plan_set << dest
			end
		    end
		end
		break if transaction_seeds.empty?

		plan_seeds.clear
	    end

	    [plan_set, transaction_set]
	end
	
	# Returns [plan_set, transaction_set], where the first is the set of
	# plan tasks matching +matcher+ and the second the set of transaction
	# tasks matching it. The two sets are disjoint.
        #
        # This will be stored by the Query object as the query result. Note
        # that, at this point, the transaction has not been modified even though
        # it applies on the global scope. New proxies will only be created when
        # Query#each is called.
	def query_result_set(matcher) # :nodoc:
	    plan_set = ValueSet.new
            if matcher.scope == :global
                plan_result_set = plan.query_result_set(matcher)
                plan.query_each(plan_result_set) do |task|
                    plan_set << task unless self[task, false]
                end
            end
	    
	    transaction_set = super
	    [plan_set, transaction_set]
	end

	# Yields tasks in the result set of +query+. Unlike Query#result_set,
	# all the tasks are included in the transaction
        #
        # +result_set+ is the value returned by #query_result_set.
	def query_each(result_set) # :nodoc:
	    plan_set, trsc_set = result_set
	    plan_set.each { |task| yield(self[task]) }
	    trsc_set.each { |task| yield(task) }
	end

	# Given the result set of +query+, returns the subset of tasks which
	# have no parent in +query+
	def query_roots(result_set, relation) # :nodoc:
	    plan_set      , trsc_set      = *result_set
	    plan_result   , trsc_result   = ValueSet.new     , ValueSet.new
	    plan_children , trsc_children = ValueSet.new     , ValueSet.new

	    for task in plan_set
		next if plan_children.include?(task)
		task_plan_children, task_trsc_children = 
		    merged_generated_subgraphs(relation, [task], [])

		plan_result -= task_plan_children
		trsc_result -= task_trsc_children
		plan_children.merge(task_plan_children)
		trsc_children.merge(task_trsc_children)

		plan_result << task
	    end

	    for task in trsc_set
		next if trsc_children.include?(task)
		task_plan_children, task_trsc_children = 
		    merged_generated_subgraphs(relation, [], [task])

		plan_result -= task_plan_children
		trsc_result -= task_trsc_children
		plan_children.merge(task_plan_children)
		trsc_children.merge(task_trsc_children)

		trsc_result << task
	    end

	    [plan_result, trsc_result]
	end
    end
end

