module Roby
    module Actions
        # Common functionality of coordination models that manipulate actions
        # (StateMachine, Script)
        class ActionCoordination < ExecutionContext
            # The action interface model that is supporting self
            attr_reader :action_interface_model
            # @return [ExecutionContext::Task] the currently active toplevel task
            attr_reader :current_task

            TaskInfo = Struct.new :required_tasks, :forwards

            # Mapping from a Models::ExecutionContext::Task object to the set of
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

            def instanciate_task(toplevel)
                task_info = self.task_info[toplevel]
                tasks, forwards = task_info.required_tasks, task_info.forwards
                tasks.each do |task, roles|
                    root_task.depends_on(
                        action_task = task.model.instanciate(action_interface_model, root_task.plan, arguments),
                        dependency_options_for(toplevel, task, roles))
                    task.bind(action_task)
                end

                @current_task = toplevel
                forwards.each do |source, target|
                    source.resolve.forward_to target.resolve
                end
            end
        end
    end
end
