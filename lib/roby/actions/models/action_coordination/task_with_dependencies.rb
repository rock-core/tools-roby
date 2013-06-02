module Roby
    module Actions
        module Models
        module ActionCoordination
        # Generic representation of an execution context task that can be
        # instanciated 
        class TaskWithDependencies < ExecutionContext::Task
            attribute(:dependencies) { Set.new }

            def depends_on(action, options = Hash.new)
                options = Kernel.validate_options options, :role
                if !action.kind_of?(InstanciatedTask)
                    raise ArgumentError, "expected a task, got #{action}. You probably forgot to convert it using #task or #state"
                end
                dependencies << [action, options[:role]]
            end
        end
        end
        end
    end
end
