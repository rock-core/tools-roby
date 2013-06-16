module Roby
    module Coordination
        # Context for all the execution objects that can be attached to the
        # action interface and/or tasks, such as state machines and scripts
        class Base
            extend Models::Base

            # The task on which this execution context is being executed. It
            # must fullfill model.task_model
            # @return [Model<Roby::Task>]
            attr_reader :root_task

            # The set of arguments given to this execution context
            # @return [Hash]
            attr_reader :arguments

            # A mapping from the model-level description of the context to the
            # instance-level description
            #
            # @see instanciate
            attr_reader :instances

            # The execution context model
            # @return [Model<Base>] a subclass of Base
            def model
                self.class
            end

            def initialize(root_task = nil, arguments = Hash.new)
                @root_task = root_task
                @arguments = Kernel.normalize_options arguments
                model.arguments.each do |key|
                    if !@arguments.has_key?(key)
                        raise ArgumentError, "expected an argument named #{key} but got none"
                    end
                end
                @instances = Hash.new
                if root_task
                    instance_for(model.root).bind(root_task)
                end
            end

            def instance_for(object)
                instances[object] ||= object.new(self)
            end
        end
    end
end
