module Roby
    module Test
        # Implementation of the #validate_state_machine context
        class ValidateStateMachine
            def initialize(test, task_or_action)
                @test = test
                @toplevel_task = @test.roby_run_planner(task_or_action)

                @state_machines =
                    @toplevel_task
                    .each_coordination_object
                    .find_all { |obj| obj.kind_of?(Coordination::ActionStateMachine) }

                if @state_machines.empty?
                    raise ArgumentError, "#{task_or_action} has no state machines"
                end
            end

            def assert_transitions_to_state(state_name, timeout: 5, start: true)
                state_name = state_name.to_str
                state_name = "#{state_name}_state" unless state_name.end_with?('_state')

                done = false
                @state_machines.each do |m|
                    m.on_transition do |_, new_state|
                        done ||= (state_name === new_state.name)
                    end
                end
                yield if block_given?
                @test.process_events_until(timeout: timeout, garbage_collect_pass: false) do
                    done
                end
                @test.roby_run_planner(@toplevel_task)
                state_task = @toplevel_task.current_task_child
                expect_execution.to { emit state_task.start_event } if start
                state_task
            end

            def evaluate(&block)
                instance_eval(&block)
            end

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    @toplevel_task, m, args,
                    '_event' => :find_event,
                    '_child' => :find_child_from_role) || super
            end

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    @toplevel_task, m,
                    '_event' => :has_event?,
                    '_child' => :has_role?) || super
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

