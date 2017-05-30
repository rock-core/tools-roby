module Roby
    module Coordination
        # Common functionality of coordination models that manipulate actions
        # (ActionStateMachine, ActionScript)
        class Actions < Base
            extend Models::Actions

            # @return [Coordination::Task] the currently active toplevel task
            attr_reader :current_task

            TaskInfo = Struct.new :required_tasks, :forwards

            # Mapping from a Coordination::Models::Task object to the set of
            # forwards that are defined for it
            attr_reader :task_info

            # Resolved captures
            #
            # This is currently only used by the {ActionStateMachine}
            #
            # @return [Hash<Models::Capture, Object>]
            attr_reader :resolved_captures

            def initialize(root_task, arguments = Hash.new)
                super(root_task, arguments)
                @task_info = resolve_task_info
                @resolved_captures = Hash.new
            end

            def action_interface_model
                model.action_interface
            end

            def task_info_for(task)
                required_tasks  = model.required_tasks_for(task).map do |t, roles|
                    [instance_for(t), roles]
                end

                forwards = Set.new
                model.each_forward do |in_task, event, target|
                    if in_task == task
                        event  = instance_for(event)
                        target = instance_for(target)
                        forwards << [event, target]
                    end
                end
                TaskInfo.new(required_tasks, forwards)
            end

            def resolve_task_info
                result = Hash.new
                model.each_task do |task|
                    result[instance_for(task)] = task_info_for(task)
                end
                result
            end

            def dependency_options_for(toplevel, task, roles)
                roles = roles.dup
                if task.name
                    roles << task.name
                end
                Hash[roles: roles,
                    failure: :stop.or(:start.never),
                    remove_when_done: true]
            end

            def start_task(toplevel, explicit_start: false)
                task_info = self.task_info[toplevel]
                tasks, forwards = task_info.required_tasks, task_info.forwards
                variables = arguments.merge(resolved_captures)

                instanciated_tasks = tasks.map do |task, roles|
                    action_task = task.model.instanciate(root_task.plan, variables)
                    root_task.depends_on(action_task, dependency_options_for(toplevel, task, roles))
                    bind_coordination_task_to_instance(task, action_task, on_replace: :copy)
                    task.model.setup_instanciated_task(self, action_task, variables)
                    action_task
                end

                @current_task = toplevel
                forwards.each do |source, target|
                    source.resolve.on do |event|
                        if target.resolve.task.running?
                            target.resolve.emit(*event.context)
                        end
                    end
                end

                instanciated_tasks
            end

            def remove_current_task
                current_task_child = root_task.find_child_from_role('current_task')
                task_info[current_task].required_tasks.each do |task, roles|
                    if state_name = task.name
                        roles = [state_name, *roles]
                    end
                    if !roles.empty? && (child_task = root_task.find_child_from_role(roles.first))
                        root_task.remove_roles(child_task, *roles)
                    end
                end
            end
        end
    end
end
