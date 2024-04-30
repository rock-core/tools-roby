# frozen_string_literal: true

module Roby
    module Coordination
        # A state machine defined on action interfaces
        #
        # In such state machine, each state is represented by the task returned
        # by the corresponding action, and the transitions are events on these
        # tasks
        class ActionStateMachine < Actions
            extend Models::ActionStateMachine

            include Hooks
            include Hooks::InstanceHooks

            define_hooks :on_transition

            # The current state
            attr_reader :current_state

            StateInfo = Struct.new :required_tasks, :forwards, :transitions, :captures

            def initialize(root_task, arguments = {})
                super(root_task, arguments)
                @task_info = resolve_state_info

                start_state = model.starting_state
                if arguments[:start_state]
                    start_state = model.find_state_by_name(arguments[:start_state])
                    unless start_state
                        raise ArgumentError,
                              "The starting state #{arguments[:start_state]} is "\
                              "unkown, make sure its defined in #{self}"
                    end
                end

                model.each_capture do |capture, (in_state, captured_event)|
                    if in_state == model.root
                        captured_event = instance_for(model.root).find_event(captured_event.symbol)
                        captured_event.resolve.once do |event|
                            if root_task.running?
                                resolved_captures[capture] = capture.filter(self, event)
                            end
                        end
                    end
                end

                root_task.execute do
                    if start_state
                        instanciate_state(instance_for(start_state))
                    end
                end
            end

            def resolve_state_info
                task_info.each_with_object({}) do |(task, task_info), h|
                    task_info = StateInfo.new(
                        task_info.required_tasks,
                        task_info.forwards,
                        Set.new, {}
                    )
                    model.each_transition do |in_state, event, new_state|
                        in_state = instance_for(in_state)
                        if in_state == task
                            task_info.transitions <<
                                [instance_for(event), instance_for(new_state)]
                        end
                    end
                    model.each_capture do |capture, (in_state, event)|
                        in_state = instance_for(in_state)
                        if in_state == task
                            task_info.captures[capture] = instance_for(event)
                        end
                    end
                    h[task] = task_info
                end
            end

            def dependency_options_for(toplevel, task, roles)
                options = super
                options[:success] = task_info[toplevel].transitions.map do |source, _|
                    source.symbol.emitted?.from_now if source.task == task
                end.compact
                options
            end

            def instanciate_state(state)
                begin
                    start_task(state)
                rescue Models::Capture::Unbound => e
                    raise e, "in the action state machine #{model} running on #{root_task} while starting #{state.name}, #{e.message}", e.backtrace
                end

                state_info = task_info[state]
                known_transitions = state_info.transitions
                captures = state_info.captures

                transitioned = false
                captures.each do |capture, captured_event|
                    captured_event.resolve.once do |event|
                        if !transitioned && root_task.running?
                            resolved_captures[capture] = capture.filter(self, event)
                        end
                    end
                end
                known_transitions.each do |source_event, new_state|
                    source_event.resolve.once do |event|
                        if !transitioned && root_task.running?
                            transitioned = true
                            begin
                                instanciate_state_transition(event.task, new_state)
                            rescue Exception => e
                                event.task.plan.add_error(
                                    ActionStateTransitionFailed.new(root_task, state, event, new_state, e)
                                )
                            end
                        end
                    end
                end
            end

            def instanciate_state_transition(task, new_state)
                remove_current_task
                instanciate_state(new_state)
                run_hook :on_transition, task, new_state
            end
        end
    end
end
