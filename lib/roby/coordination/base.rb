module Roby
    module Coordination
        # Context for all the execution objects that can be attached to the
        # action interface and/or tasks, such as state machines and scripts
        class Base
            extend Models::Base

            # The task on which this execution context is being executed. It
            # must fullfill model.task_model
            # @return [Model<Roby::Task>]
            def root_task
                instance_for(model.root).task
            end

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

            # Create a new coordination instance. The model is represented by
            # this object's class
            #
            # @param [Roby::Task] root_task the task instance that should be
            #   bound to {Models::Base#root}
            # @param [Hash] arguments parametrization of this coordination
            #   object. The list of known arguments is in
            #   {Models::Base#arguments}
            # @param [Hash] options
            # @option options [:drop,:copy] :on_replace (:drop) defines what
            #   should be done if the root task gets replaced. :drop means that
            #   the state machine should not be passed to the new task. :copy
            #   means that it should. Note that it only affects the root task.
            #   All other tasks that are referred to inside the coordination
            #   model are tracked for replacements.
            # @option options [nil,Base] :parent (nil) the parent coordination
            #   model. This is used so that the coordination tasks can be shared
            #   across instances
            def initialize(root_task = nil, arguments = Hash.new, options = Hash.new)
                options = Kernel.validate_options options, :on_replace => :drop, :parent => nil
                @root_task = root_task
                @arguments = Kernel.normalize_options arguments
                model.arguments.each do |key|
                    if !@arguments.has_key?(key)
                        raise ArgumentError, "expected an argument named #{key} but got none"
                    end
                end
                @instances = Hash.new
                if root_task
                    bind_coordination_task_to_instance(instance_for(model.root), root_task, :on_replace => options[:on_replace])
                end
            end

            def bind_coordination_task_to_instance(coordination_task, instance, options = Hash.new)
                options = Kernel.validate_options options, :on_replace => :drop

                coordination_task.bind(instance)
                if options[:on_replace] == :copy
                    instance.as_service.on_replacement do |old_task, new_task|
                        coordination_task.bind(new_task)
                    end
                end
            end

            def instance_for(object)
                instances[object] ||= object.new(self)
            end
        end
    end
end
