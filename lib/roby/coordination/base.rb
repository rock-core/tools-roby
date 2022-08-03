# frozen_string_literal: true

module Roby
    module Coordination
        # Context for all the execution objects that can be attached to the
        # action interface and/or tasks, such as state machines and scripts
        class Base
            extend Models::Base

            # The parent coordination object
            #
            # @return [nil,Base]
            attr_reader :parent

            # The task on which this execution context is being executed. It
            # must fullfill model.task
            # @return [Model<Roby::Task>]
            def root_task
                instance_for(model.root).task
            end

            # The plan this coordination object is part of
            def plan
                root_task.plan
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
            #   object. The list of known arguments can be accessed with
            #   model.arguments (defined by {Models::Arguments}.
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
            def initialize(root_task = nil, arguments = {}, options = {})
                options = Kernel.validate_options options, on_replace: :drop, parent: nil

                @arguments = model.validate_arguments(arguments)
                @parent = options[:parent]
                @instances = {}
                if root_task
                    bind_coordination_task_to_instance(
                        instance_for(model.root),
                        root_task,
                        on_replace: options[:on_replace])
                    root_task.add_coordination_object(self)

                    attach_fault_response_tables_to(root_task)

                    if options[:on_replace] == :copy
                        root_task.as_service.on_replacement do |old_task, new_task|
                            old_task.remove_coordination_object(self)
                            new_task.add_coordination_object(self)
                            attach_fault_response_tables_to(new_task)
                        end
                    end
                end
            end

            def attach_fault_response_tables_to(_task)
                model.each_used_fault_response_table do |table, arguments|
                    arguments = arguments.transform_values do |val|
                        if val.kind_of?(Models::Variable)
                            self.arguments[val.name]
                        else val
                        end
                    end
                    root_task.use_fault_response_table(table, arguments)
                end
            end

            # Binds a task instance to the coordination task
            #
            # This method binds a task instance to the coordination task it
            # represents, and optionally installs the handlers necessary to
            # track replacement
            #
            # @param [Coordination::Task] coordination_task the coordination task
            # @param [Roby::Task] instance the task
            # @option options [Symbol] :on_replace (:drop) what should be done
            #   if the task instance is replaced by another task. If :drop, the
            #   coordination task will be reset to nil. If :copy, it will track
            #   the new task
            # @return [void]
            def bind_coordination_task_to_instance(coordination_task, instance, options = {})
                options = Kernel.validate_options options, on_replace: :drop

                coordination_task.bind(instance)
                if options[:on_replace] == :copy
                    instance.as_service.on_replacement do |old_task, new_task|
                        coordination_task.bind(new_task)
                    end
                end
            end

            # Returns the instance-level coordination task that is used to
            # represent a model-level coordination task
            #
            # Coordination models are built using instances of
            # {Coordination::Models::Task} (or its subclasses). When they get
            # instanciated into actual coordination objects, these are
            # uniquely associated with instances of {Coordination::Task} (or its
            # subclasses).
            #
            # This method can be used to retrieve the unique object associated
            # with a given model-level coordination task
            #
            # @param [Coordination::Models::Task] object the model-level coordination task
            # @return [Coordination::Task] object the instance-level coordination task
            def instance_for(object)
                if (ins = instances[object])
                    ins
                elsif parent && (ins = parent.instances[object])
                    ins
                else
                    instances[object] = object.new(self)
                end
            end
        end
    end
end
