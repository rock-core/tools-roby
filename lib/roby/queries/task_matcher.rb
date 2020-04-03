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

            # Initializes an empty TaskMatcher object
            def initialize
                super
                @arguments = {}
                @interruptible = nil
            end

            def to_s
                result = super
                unless arguments.empty?
                    args_to_s = arguments.map { |k, v| ":#{k} => #{v}" }.join(', ')
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
                self.arguments.merge!(arguments) do |k, old, new|
                    if old != new
                        raise ArgumentError,
                              "a constraint has already been set on the #{k} argument"
                    end
                    old
                end
                self
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
                :starting?, :pending?, :running?, :finished?, :success?, :failed?,
                :interruptible?
            )

            # Finishing tasks are also running task, use the index on 'running'
            match_predicate :finishing?, [[:running?], []]

            # Reusable tasks must be neither finishing nor finished
            match_predicate :reusable?, [[], [:finished?]]

            # Helper method for #with_child and #with_parent
            def handle_parent_child_arguments(other_query, relation, relation_options)
                if !other_query.kind_of?(TaskMatcher) && !other_query.kind_of?(Task)
                    if relation.kind_of?(Hash)
                        arguments = relation
                        relation = (arguments.delete(:relation) ||
                                    arguments.delete('relation'))
                        relation_options = (
                            arguments.delete(:relation_options) ||
                            arguments.delete('relation_options')
                        )
                    else
                        arguments = {}
                    end
                    other_query = TaskMatcher.which_fullfills(other_query, arguments)
                end
                [relation, [other_query, relation_options]]
            end

            # True if +task+ matches all the criteria defined on this object.
            def ===(task)
                return unless task.kind_of?(Roby::Task)
                return unless task.arguments.slice(*arguments.keys) == arguments

                super
            end

            # Returns true if filtering with this TaskMatcher using #=== is
            # equivalent to calling #filter() using a Index. This is used to
            # avoid an explicit O(N) filtering step after filter() has been called
            def indexed_query?
                arguments.empty? && super
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
                m.to_s.end_with?('_event') || super
            end

            def method_missing(m, *args)
                m_string = m.to_s
                return super unless m_string.end_with?('_event')

                event_name = m[0..-7]
                model = find_event(event_name)
                if !model
                    task_models = @model.empty? ? [Roby::Task] : @model
                    raise NoMethodError.new(m),
                          "no event '#{event_name}' in match model "\
                          "#{task_models.map(&:to_s).join(', ')}, use "\
                          '#which_fullfills to narrow the task model'
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
        end
    end
end
