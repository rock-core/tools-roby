# frozen_string_literal: true

module Roby
    module Queries
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
        class TaskMatcher < PlanObjectMatcher
            # Set of arguments that should be tested on the task
            #
            # @return [Hash]
            attr_reader :arguments

            PLAN_PREDICATES = {
                mission_task?: :mission_tasks,
                permanent_task?: :permanent_tasks
            }.freeze

            # @api private
            #
            # Set of predicates specific to the plan (e.g. mission/permanent)
            attr_reader :plan_predicates

            # @api private
            #
            # Set of predicates specific to the plan (e.g. mission/permanent)
            attr_reader :neg_plan_predicates

            # Initializes an empty TaskMatcher object
            def initialize
                super
                @arguments = {}
                @indexed_query = !@instance
                @plan_predicates = Set.new
                @neg_plan_predicates = Set.new
            end

            def to_s
                result = super
                unless arguments.empty?
                    args_to_s = arguments.map { |k, v| ":#{k} => #{v}" }.join(", ")
                    result << ".with_arguments(#{args_to_s})"
                end
                result
            end

            # Filters on task model and arguments
            #
            # Will match if the task is an instance of +model+ or one of its
            # subclasses, and if parts of its arguments are the ones provided. Set
            # +arguments+ to nil if you don't want to filter on arguments.
            def which_fullfills(model, arguments = nil)
                with_model(model)
                with_model_arguments(arguments) if arguments
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
            #   task = TaskModel.new(a: 10, b: 20)
            #
            #   # Matches on :a, :b is ignored altogether
            #   TaskMatcher.new.
            #       with_model(TaskModel).
            #       with_model_arguments(a: 10) === task # => true
            #   # Looks for both :a and :b
            #   TaskMatcher.new.
            #       with_model(TaskModel).
            #       with_model_arguments(a: 10, b: 30) === task # => false
            #   # Matches on :a, :c is ignored as it is not an argument of +TaskModel+
            #   TaskMatcher.new.
            #       with_model(TaskModel).
            #       with_model_arguments(a: 10, c: 30) === task # => true
            #
            # In general, one would use #which_fullfills, which sets both the model
            # and the model arguments
            def with_model_arguments(arguments)
                valid_arguments = model.inject([]) do |set, model|
                    set | model.arguments.to_a
                end
                with_arguments(arguments.slice(*valid_arguments))
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
            #   task = TaskModel.new(a: 10, b: 20)
            #
            #   # Matches on :a, :b is ignored altogether
            #   TaskMatcher.new.
            #       with_arguments(a: 10) === task # => true
            #   # Looks for both :a and :b
            #   TaskMatcher.new.
            #       with_arguments(a: 10, b: 30) === task # => false
            #   # Looks for both :a and :c, even though :c is not declared in TaskModel
            #   TaskMatcher.new.
            #       with_arguments(a: 10, c: 30) === task # => false
            def with_arguments(arguments)
                @arguments ||= {}
                @indexed_query = false
                self.arguments.merge!(arguments) do |k, old, new|
                    if old != new
                        raise ArgumentError,
                              "a constraint has already been set on the #{k} argument"
                    end
                    old
                end
                self
            end

            def add_predicate(name)
                @indexed_query = false unless Index::PREDICATES.include?(name)

                super
            end

            def add_neg_predicate(name)
                @indexed_query = false unless Index::PREDICATES.include?(name)

                super
            end

            class << self
                # @api private
                def match_indexed_predicate(
                    name,
                    index: name.to_s, neg_index: nil,
                    not_index: nil, not_neg_index: name.to_s
                )
                    method_name = name.to_s.gsub(/\?$/, "")
                    class_eval <<~PREDICATE_METHOD, __FILE__, __LINE__ + 1
                        def #{method_name}
                            add_predicate(:#{name})
                            #{"indexed_predicates << :#{index}" if index}
                            #{"indexed_neg_predicates << :#{neg_index}" if neg_index}
                            self
                        end
                        def not_#{method_name}
                            add_neg_predicate(:#{name})
                            #{"indexed_predicates << :#{not_index}" if not_index}
                            #{"indexed_neg_predicates << :#{not_neg_index}" if not_neg_index}
                            self
                        end
                    PREDICATE_METHOD
                    declare_class_methods(method_name, "not_#{method_name}")
                end

                def match_indexed_predicates(*names)
                    names.each do |n|
                        unless Index::PREDICATES.include?(n)
                            raise ArgumentError,
                                  "#{n} is not declared in Index::PREDICATES. Use "\
                                  "match_indexed_predicate directly to override "\
                                  "this check"
                        end

                        match_indexed_predicate(n)
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

            match_predicates(
                :abstract?, :partially_instanciated?, :fully_instanciated?,
                :interruptible?
            )

            match_indexed_predicates(
                :starting?, :pending?, :running?, :finished?, :success?, :failed?
            )

            # Finishing tasks are also running task, use the index on 'running'
            match_indexed_predicate :finishing?, index: :running?, neg_index: nil,
                                                 not_index: nil, not_neg_index: nil

            # Reusable tasks must be neither finishing nor finished
            match_indexed_predicate :reusable?, index: nil, neg_index: :finished?,
                                                not_index: nil, not_neg_index: nil

            # @api private
            #
            # Helper to add a plan predicate in the match set
            def add_plan_predicate(predicate)
                if !PLAN_PREDICATES.key?(predicate)
                    raise ArgumentError, "unknown plan predicate #{predicate}"
                elsif @neg_plan_predicates.include?(predicate)
                    raise ArgumentError, "trying to match #{predicate} & not_#{predicate}"
                end

                @plan_predicates << predicate
                self
            end

            # @api private
            #
            # Helper to add a plan predicate in the match set
            def add_neg_plan_predicate(predicate)
                if !PLAN_PREDICATES.key?(predicate)
                    raise ArgumentError, "unknown plan predicate #{predicate}"
                elsif @plan_predicates.include?(predicate)
                    raise ArgumentError, "trying to match #{predicate} & not_#{predicate}"
                end

                @neg_plan_predicates << predicate
                self
            end

            # Matches if the task is a mission
            def mission
                add_plan_predicate :mission_task?
            end

            # Matches if the task is not a mission
            def not_mission
                add_neg_plan_predicate :mission_task?
            end

            declare_class_methods "mission", "not_mission"

            # Matches if the task is permanent
            def permanent
                add_plan_predicate :permanent_task?
            end

            # Matches if the task is not permanent
            def not_permanent
                add_neg_plan_predicate :permanent_task?
            end

            declare_class_methods "permanent", "not_permanent"

            # Helper method for #with_child and #with_parent
            def handle_parent_child_arguments(other_query, relation, relation_options)
                if !other_query.kind_of?(TaskMatcher) && !other_query.kind_of?(Task)
                    if relation.kind_of?(Hash)
                        arguments = relation
                        relation = (arguments.delete(:relation) ||
                                    arguments.delete("relation"))
                        relation_options = (
                            arguments.delete(:relation_options) ||
                            arguments.delete("relation_options")
                        )
                    else
                        arguments = {}
                    end
                    other_query = TaskMatcher.which_fullfills(other_query, arguments)
                end
                [relation, [other_query, relation_options]]
            end

            # True if +task+ matches all the criteria defined on this object.
            def ===(task) # rubocop:disable Metrics/CyclomaticComplexity
                return unless task.kind_of?(Roby::Task)
                return unless task.arguments.slice(*arguments.keys) == arguments
                return unless super
                return unless (plan = task.plan)
                return unless @plan_predicates.all? { |pred| plan.send(pred, task) }
                return if @neg_plan_predicates.any? { |pred| plan.send(pred, task) }

                true
            end

            # Returns true if filtering with this TaskMatcher using #=== is
            # equivalent to calling #filter() using a Index. This is used to
            # avoid an explicit O(N) filtering step after filter() has been called
            def indexed_query?
                @indexed_query
            end

            # @api private
            #
            # Resolve the indexed sets needed to filter an initial set in {#filter}
            #
            # @return [(Set,Set)] the positive (intersection) and
            #   negative (difference) sets. The result will be computed as
            #    positive.inject(&:&) - negative.inject(&:|)
            def indexed_sets(index)
                positive_sets = []
                @model.each do |m|
                    positive_sets << index.by_model[m]
                end

                @owners.each do |o|
                    candidates = index.by_owner[o]
                    return [Set.new, Set.new] unless candidates

                    positive_sets << candidates
                end

                @indexed_predicates.each do |pred|
                    positive_sets << index.by_predicate[pred]
                end

                negative_sets =
                    @indexed_neg_predicates
                    .map { |pred| index.by_predicate[pred] }

                @plan_predicates.each do |name|
                    positive_sets << index.send(PLAN_PREDICATES.fetch(name))
                end

                @neg_plan_predicates.each do |name|
                    negative_sets << index.send(PLAN_PREDICATES.fetch(name))
                end

                [positive_sets, negative_sets]
            end

            # @deprecated use {#filter_tasks_sets} instead
            def filter(initial_set, index, initial_is_complete: false)
                Roby.warn_deprecated "TaskMatcher#filter is deprecated, "\
                                     "use {#filter_tasks_sets} instead"
                filter_tasks_sets(initial_set, index,
                                  initial_is_complete: initial_is_complete)
            end

            # Filters tasks from an initial set to remove as many not-matching
            # tasks as possible
            #
            # If {#indexed_query?} is true, the result is required to be exact
            # (i.e. return exactly all tasks in initial_set that match the query)
            #
            # @param [Set] initial_set
            # @param [Index] index
            # @return [([Set],[Set])] a list of 'positive' sets and a list of 'negative'
            #    sets. The result is computed as
            #    positive.inject(&:&) - negative.inject(&:|)
            def filter_tasks_sets(initial_set, index, initial_is_complete: false)
                positive_sets, negative_sets = indexed_sets(index)
                if !initial_is_complete || positive_sets.empty?
                    positive_sets << initial_set
                end

                negative = negative_sets.shift || Set.new
                unless negative_sets.empty?
                    negative = negative.dup
                    negative_sets.each { |set| negative.merge(set) }
                end

                positive_sets = positive_sets.sort_by(&:size)

                result = Set.new
                result.compare_by_identity
                positive_sets.shift.each do |obj|
                    next if negative.include?(obj)

                    result.add(obj) if positive_sets.all? { |set| set.include?(obj) }
                end
                result
            end

            def find_event(event_name)
                event_name = event_name.to_sym
                models = if !@model.empty?
                             @model
                         else
                             [Roby::Task]
                         end
                models.each do |m|
                    if m.find_event(event_name)
                        return TaskEventGeneratorMatcher.new(self, event_name)
                    end
                end
                nil
            end

            def respond_to_missing?(m, include_private)
                m.to_s.end_with?("_event") || super
            end

            def method_missing(m, *args)
                m_string = m.to_s
                return super unless m_string.end_with?("_event")

                event_name = m[0..-7]
                model = find_event(event_name)
                if !model
                    task_models = @model.empty? ? [Roby::Task] : @model
                    raise NoMethodError.new(m),
                          "no event '#{event_name}' in match model "\
                          "#{task_models.map(&:to_s).join(', ')}, use "\
                          "#which_fullfills to narrow the task model"
                elsif !args.empty?
                    raise ArgumentError,
                          "#{m} expected zero arguments, got #{args.size}"
                end

                TaskEventGeneratorMatcher.new(self, event_name)
            end

            # Define singleton classes. For instance, calling
            # TaskMatcher.which_fullfills is equivalent to
            # TaskMatcher.new.which_fullfills
            declare_class_methods :which_fullfills, :with_arguments

            # @api private
            #
            # Resolves or returns the cached set of matching tasks in the plan
            #
            # This is a cached value, so use {#reset} to actually recompute
            # this set.
            #
            # This should not be called directly. Use {#each_in_plan}
            def evaluate(plan)
                plan.query_result_set(self)
            end

            # Enumerate the objects matching self in the plan
            #
            # This resolves the query only the first time. After the first call,
            # the same set of tasks will be returned. Use {#reset} to clear the
            # cached results.
            def each_in_plan(plan, &block)
                return enum_for(__method__, plan) unless block_given?

                evaluate(plan).each_in_plan(plan, &block)
            end

            # Filters tasks which have no parents in the query itself.
            #
            # Will filter out tasks which have parents in +relation+ that are
            # included in the query result.
            #
            # @return [#each_in_plan]
            def roots(plan, in_relation)
                evaluate(plan).roots(in_relation)
                self
            end

            # Computes the union of two predicates
            #
            # The returned task matcher will yield tasks that are matched by any
            # of its the elements.
            #
            # Roby does only supports computing the OR of task matchers (cannot
            # combine different operators)
            def |(other)
                result = OrMatcher::Tasks.new
                result << self
                case other
                when OrMatcher::Tasks
                    result.merge(other)
                when TaskMatcher
                    result << other
                else
                    raise ArgumentError,
                          "cannot compute the union of a TaskMatcher with #{other}"
                end
            end

            # Computes the intersection of two predicates
            #
            # The returned task matcher will yield tasks that are matched by all
            # the elements.
            #
            # Roby does only supports computing the AND of task matchers (cannot
            # combine different operators)
            def &(other)
                result = AndMatcher::Tasks.new
                result << self
                case other
                when AndMatcher::Tasks
                    result.merge(other)
                when TaskMatcher
                    result << other
                else
                    raise ArgumentError,
                          "cannot compute the intersection of a TaskMatcher with #{other}"
                end
            end

            # Negates this predicate
            #
            # The returned task matcher will yield tasks that are *not* matched by
            # +self+
            def negate
                NotMatcher::Tasks.new(self)
            end
        end
    end
end
