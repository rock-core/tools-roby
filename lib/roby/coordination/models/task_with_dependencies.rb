# frozen_string_literal: true

module Roby
    module Coordination
        module Models
            # Generic representation of an execution context task that can be
            # instanciated
            class TaskWithDependencies < Task
                # @return [Set<(Task,String)>] set of dependencies needed for this
                #   task, as a (task,role) pair
                attr_reader :dependencies

                # (see Task#initialize)
                def initialize(model)
                    super
                    @dependencies = Set.new
                end

                def initialize_copy(old)
                    super
                    @dependencies = @dependencies.dup
                end

                # Modify this task's internal structure to change relationships
                # between tasks
                def map_tasks(mapping)
                    super
                    @dependencies = dependencies.map do |task, role|
                        [mapping[task] || task, role]
                    end
                end

                def find_child_model(name)
                    if d = dependencies.find { |_, role| role == name }
                        d[0].model
                    else super
                    end
                end

                def depends_on(action, role: nil)
                    unless action.kind_of?(Coordination::Models::Task)
                        raise ArgumentError, "expected a task, got #{action}. You probably forgot to convert it using #task or #state"
                    end

                    dependencies << [action, role]
                    self
                end
            end
        end
    end
end
