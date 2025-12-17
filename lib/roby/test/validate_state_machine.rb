# frozen_string_literal: true

module Roby
    module Test
        # DSL-like way to test an action state machine
        #
        # {ValidateStateMachine} objects are not created directly. Use
        # {Assertions#validate_state_machine} to create them
        #
        # The goal of state machine validation is to verify that state
        # transitions happen when they should in complex state machines and in
        # state machine generators (i.e. methods that create state machines)
        #
        # The general workflow is to verify some properties on the start state,
        # and then cause state machine transitions using
        # {#assert_transitions_to_state} based on e.g. event emissions. Do not
        # fall into the trap of testing the state's own behaviors. This should
        # be done within separate unit tests for the state's actions and/or
        # task implementations.
        class ValidateStateMachine
            # The task that holds the state machine
            #
            # @return [Roby::Task]
            attr_reader :toplevel_task

            # The toplevel task of the current state
            #
            # It raises if the toplevel task (and thus, the state machine) are
            # not running
            #
            # @return [Roby::Task]
            def current_state_task
                @toplevel_task.current_task_child
            end

            def initialize(test, task_or_action)
                @test = test
                @toplevel_task = @test.run_planners(task_or_action)

                @state_machines =
                    @toplevel_task
                    .each_coordination_object
                    .find_all { |obj| obj.kind_of?(Coordination::ActionStateMachine) }

                return unless @state_machines.empty?

                raise ArgumentError, "#{task_or_action} has no state machines"
            end

            # Start the toplevel task
            #
            # This is done automatically by {Assertions#validate_state_machine}
            def start
                toplevel_task = @toplevel_task
                expect_execution { toplevel_task.start! }
                    .to { emit toplevel_task.start_event }
                @toplevel_task = @test.run_planners(@toplevel_task)
                @toplevel_task.current_task_child
            end

            # Returns possible state names based on current patterns and the
            # actual state name
            def state_name_patterns(state_name)
                matchers = [state_name.to_str]
                matchers << "#{state_name}_state" unless state_name.end_with?("_state")
                matchers
            end

            # Verifies that some operations cause the state machine to transition
            #
            # Note that one assertion may wait for more than one state transition.
            # The given block should cause the expected transition(s) to fire, and
            # should use normal Roby testing tools, such as e.g.
            # {ExpectExecution#expect_execution}
            #
            # The toplevel task **MUST** be active at the point of call, that
            # is the toplevel task has been started
            #
            # @yieldparam [Roby::Task] the current state's task
            # @param [String,Symbol] state_name the name of the target state
            # @param [Numeric] timeout
            def assert_transitions_to_state(state_name, timeout: 5)
                matchers = state_name_patterns(state_name)

                done = false
                @state_machines.each do |m|
                    m.on_transition do |_, new_state|
                        done ||= matchers.any? do
                            (_1 === new_state.name)
                        end
                    end
                end
                yield(current_state_task) if block_given?
                expect_execution.timeout(timeout).to { achieve { done } }
                @test.run_planners(@toplevel_task)
                @toplevel_task.current_task_child
            end

            def evaluate(&block)
                instance_eval(&block)
            end

            FIND_THROUGH_METHOD_MISSING = {
                "_event" => :find_event,
                "_child" => :find_child_from_role
            }.freeze

            HAS_THROUGH_METHOD_MISSING = {
                "_event" => :has_event?,
                "_child" => :has_role?
            }.freeze

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    current_state_task, m, args, FIND_THROUGH_METHOD_MISSING
                ) || super
            end

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    current_state_task, m, HAS_THROUGH_METHOD_MISSING
                ) || super
            end

            include MetaRuby::DSLs::FindThroughMethodMissing

            def respond_to_missing?(m, include_private)
                @test.respond_to?(m) || super
            end

            def method_missing(m, *args, &block)
                if @test.respond_to?(m)
                    @test.public_send(m, *args, &block)
                else
                    super
                end
            end
        end
    end
end
