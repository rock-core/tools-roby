module Roby
    module Actions
        # Context for all the execution objects that can be attached to the
        # action interface and/or tasks, such as state machines and scripts
        class ExecutionContext
            extend ExecutionContextModel

            # The task on which this execution context is being executed. It
            # must fullfill model.task_model
            # @return [Model<Roby::Task>]
            attr_reader :root_task

            # The set of arguments given to this execution context
            # @return [Hash]
            attr_reader :arguments

            # The execution context model
            # @return [Model<ExecutionContext>] a subclass of ExecutionContext
            def model
                self.class
            end

            def initialize(root_task, arguments = Hash.new)
                @root_task = root_task
                @arguments = Kernel.normalize_options arguments
                model.arguments.each do |key|
                    if !@arguments.has_key?(key)
                        raise ArgumentError, "expected an argument named #{key} but got none"
                    end
                end
            end
        end
    end
end
