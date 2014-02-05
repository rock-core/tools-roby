module Roby
    module Coordination
        module Models
        # Generic representation of an execution context task that can be
        # instanciated 
        class TaskWithDependencies < Task
            attribute(:dependencies) { Set.new }

            def find_child_model(name)
                if d = dependencies.find { |_, role| role == name }
                    d[0].model
                end
            end

            def depends_on(action, options = Hash.new)
                options = Kernel.validate_options options, :role
                if options[:role].nil?
                    raise ArgumentError, "You have to pass a role for the depending child"
                end
                if !action.kind_of?(Coordination::Models::Task)
                    raise ArgumentError, "expected a task, got #{action}. You probably forgot to convert it using #task or #state"
                end
                dependencies << [action, options[:role]]
            end

            def setup_instanciated_task(coordination_context, task, arguments = Hash.new)
                super if defined? super
            end
        end
        end
    end
end
