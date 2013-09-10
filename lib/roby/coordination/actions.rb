module Roby
    module Coordination
        # Common functionality of coordination models that manipulate actions
        # (ActionStateMachine, ActionScript)
        class Actions < Base
            # The action interface model that is supporting self
            attr_reader :action_interface_model
            # @return [Coordination::Task] the currently active toplevel task
            attr_reader :current_task

            TaskInfo = Struct.new :required_tasks, :forwards

            # Mapping from a Coordination::Models::Task object to the set of
            # forwards that are defined for it
            attr_reader :task_info

            def initialize(action_interface_model, root_task, arguments = Hash.new)
                super(root_task, arguments)
                @action_interface_model = action_interface_model
                @task_info = resolve_task_info
            end

            def resolve_task_info
                result = Hash.new
                model.each_task do |task|
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
                    result[instance_for(task)] = TaskInfo.new(required_tasks, forwards)
                end
                result
            end

            def dependency_options_for(toplevel, task, roles)
                Hash[:roles => roles,
                    :failure => :stop.or(:start.never),
                    :remove_when_done => true]
            end

            def start_task(toplevel)
                task_info = self.task_info[toplevel]
                tasks, forwards = task_info.required_tasks, task_info.forwards
                tasks.each do |task, roles|
                    action_task = task.model.instanciate(root_task.plan, arguments)
                    root_task.depends_on(action_task, dependency_options_for(toplevel, task, roles))
                    bind_coordination_task_to_instance(task, action_task, :on_replace => :copy)
                    task.model.setup_instanciated_task(self, action_task, arguments)
                end

                @current_task = toplevel
                forwards.each do |source, target|
                    source.resolve.on do |event|
                        if target.resolve.task.running?
                            target.resolve.emit
                        end
                    end
                end
            end

            def remove_current_task
                current_task_child = root_task.find_child_from_role('current_task')
                task_info[current_task].required_tasks.each do |_, roles|
                    if child_task = root_task.find_child_from_role(roles.first)
                        root_task.remove_dependency(child_task)
                    end
                end
            end
        end
    end
end
