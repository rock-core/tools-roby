module Roby
    module Coordination
        module Models
        # Generic representation of an execution context task that can be
        # instanciated 
        class TaskWithDependencies < Task
            attribute(:dependencies) { Set.new }

            def depends_on(action, options = Hash.new)
                options = Kernel.validate_options options, :role
                if !action.kind_of?(Coordination::Models::Task)
                    raise ArgumentError, "expected a task, got #{action}. You probably forgot to convert it using #task or #state"
                end
                dependencies << [action, options[:role]]
            end
        end
        end
    end
end
