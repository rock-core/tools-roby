module Roby
    module Actions
        # A state machine defined on action interfaces
        #
        # In such state machine, each state is represented by the task returned
        # by the corresponding action, and the transitions are events on these
        # tasks
        class StateMachine < ActionCoordination
            extend Models::StateMachine

            # The current state
            attr_reader :current_state

            StateInfo = Struct.new :required_tasks, :forwards, :transitions

            def initialize(action_interface_model, root_task, arguments = Hash.new)
                super(action_interface_model, root_task, arguments)
                @task_info = resolve_state_info
                root_task.execute do
                    if model.starting_state
                        instanciate_state(instance_for(model.starting_state))
                    end
                end
            end

            def resolve_state_info
                task_info.map_value do |task, task_info|
                    task_info = StateInfo.new(task_info.required_tasks, task_info.forwards, Set.new)
                    model.each_transition do |in_state, event, new_state|
                        in_state = instance_for(in_state)
                        if in_state == task
                            task_info.transitions << [instance_for(event), instance_for(new_state)]
                        end
                    end
                    task_info
                end
            end

            def dependency_options_for(toplevel, task, roles)
                options = super
                options[:success] = task_info[toplevel].transitions.map do |source, _|
                    source.symbol if source.task == task
                end.compact
                options
            end

            def instanciate_state(state)
                instanciate_task(state)
                state_info = task_info[state]
                tasks, known_transitions = state_info.required_tasks, state_info.transitions
                tasks.each do |task, roles|
                    known_transitions.each do |source_event, new_state|
                        source_event.resolve.on do |event|
                            instanciate_state_transition(event.task, new_state)
                        end
                    end
                end
            end

            def instanciate_state_transition(task, new_state)
                remove_current_task
                instanciate_state(new_state)
            end
        end
    end
end

