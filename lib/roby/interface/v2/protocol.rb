# frozen_string_literal: true

module Roby
    module Interface
        module V2
            # Protocol definition for communications in the Interface protocol
            #
            # Nothing else than this and basic types is allowed
            #
            # @see Channel
            module Protocol
                Action = Struct.new :model, :arguments
                ActionModel = Struct.new(
                    :planner_name, :name, :doc, :arguments, :advanced, keyword_init: true
                ) do
                    def advanced?
                        advanced
                    end

                    def pp_arguments(pp)
                        pp.nest(2) do
                            arguments.each do |arg|
                                pp.breakable
                                arg.pretty_print(pp)
                            end
                        end
                    end

                    def pretty_print(pp)
                        args = arguments.map(&:name).join(", ")
                        pp.text "#{planner_name}.#{name}(#{args})"
                        pp.breakable
                        pp.text doc
                        pp.breakable
                        pp.text "Arguments"
                        pp_arguments(pp)
                    end
                end

                ActionArgument = Struct.new(
                    :name, :doc, :required, :default, :example, keyword_init: true
                ) do
                    def required?
                        required
                    end

                    def pretty_print(pp)
                        req_opt =
                            if required?
                                "[required]"
                            else
                                "[optional]"
                            end

                        default = " default=#{default}" unless Protocol.void?(default)

                        pp.text "#{name} #{req_opt} #{doc}#{default}"
                        unless Protocol.void?(example)
                            pp.breakable
                            pp.text "  example: #{example}"
                        end

                        nil
                    end
                end

                Task = Struct.new(
                    :id, :model, :state, :started_since, :arguments, keyword_init: true
                ) do
                    def pretty_print(pp)
                        pp.text "#{model}<id:#{id}> #{state}"
                        if started_since
                            pp.breakable
                            pp.text "Started for: #{started_since}"
                        end
                        pp.breakable
                        pp_arguments(pp)
                    end

                    def pp_arguments(pp)
                        pp.text "Arguments"
                        pp.nest(2) do
                            arguments.each do |name, arg|
                                pp.breakable
                                pp.text name.to_s
                                pp.text ": "
                                arg.pretty_print(pp)
                            end
                        end
                    end
                end

                Error = Struct.new(
                    :class_name, :message, :backtrace, keyword_init: true
                ) do
                    def pretty_print(pp)
                        pp.text "#{message} (#{class_name})"
                        pp.nest(2) do
                            backtrace.each do |line|
                                pp.breakable
                                pp.text line
                            end
                        end
                    end
                end

                ExecutionException = Struct.new(
                    :exception, :failed_task, :involved_tasks, keyword_init: true
                )

                DelayedArgumentFromState =
                    Struct.new(:object, :path, keyword_init: true)

                class VoidClass; end
                Void = VoidClass.new.freeze
                def self.void?(value)
                    value.kind_of?(VoidClass)
                end

                @marshallers = {}
                @allowed_objects = Set.new

                def self.allow_classes(*classes)
                    add_marshaller(*classes) { _2 }
                end

                def self.allow_objects(*objects)
                    @allowed_objects.merge(objects)
                end

                def self.add_marshaller(*classes, &block)
                    classes.each { @marshallers[_1] = block }
                end

                def self.each_marshaller(&block)
                    @marshallers.each(&block)
                end

                def self.register_marshallers(protocol)
                    protocol.allow_classes(
                        Action,
                        ActionArgument,
                        Error,
                        VoidClass,
                        CommandLibrary::InterfaceCommands,
                        Command,
                        ExecutionException,
                        Time
                    )

                    protocol.add_marshaller(
                        Actions::Models::Action, &method(:marshal_action_model)
                    )
                    protocol.add_marshaller(Actions::Action, &method(:marshal_action))
                    protocol.add_marshaller(Roby::Task, &method(:marshal_task))
                    protocol.add_marshaller(Roby::VoidClass) { Void }
                    protocol.add_marshaller(::Exception, &method(:marshal_exception))
                    protocol.add_marshaller(
                        Roby::ExecutionException, &method(:marshal_execution_exception)
                    )
                    protocol.add_marshaller(
                        Roby::DelayedArgumentFromState,
                        &method(:marshal_delayed_argument_from_state)
                    )
                end

                # Configure channel marshalling to convert Roby classes into their
                # protocol equivalent
                #
                # @param [Channel] channel
                def self.setup_channel(channel)
                    each_marshaller do |klass, block|
                        channel.add_marshaller(klass, &block)
                    end

                    channel.allow_objects(*@allowed_objects)
                end

                # Convert a {Actions::Models::Action::Argument}
                #
                # @param [Channel] channel
                # @param [Roby::Actions::Models::Action::Argument] action_arguments
                # @return [ActionArgument]
                def self.marshal_action_argument_model(channel, action_argument)
                    Protocol::ActionArgument.new(
                        **channel.marshal_filter_object(action_argument.to_h)
                    )
                end

                # Convert a {Actions::Action}
                #
                # @param [Channel] channel
                # @param [Roby::Actions::Action] action
                # @return [Action]
                def self.marshal_action(channel, action)
                    Action.new(
                        model: marshal_action_model(channel, action.model),
                        arguments: channel.marshal_filter_object(action)
                    )
                end

                # Convert a {Actions::Models::Action}
                #
                # @param [Channel] channel
                # @param [Roby::Actions::Models::Action] action
                # @return [ActionModel]
                def self.marshal_action_model(channel, action, planner_model: nil)
                    arguments = action.arguments.map do
                        marshal_action_argument_model(channel, _1)
                    end
                    ActionModel.new(
                        planner_name: planner_model&.name,
                        name: action.name,
                        doc: action.doc,
                        arguments: arguments,
                        advanced: action.advanced?
                    )
                end

                # Convert a {Roby::Task}
                #
                # @param [Channel] channel
                # @param [Roby::Task] task
                # @return [ActionModel]
                def self.marshal_task(channel, task)
                    Task.new(
                        id: task.droby_id.id,
                        model: task.model.name,
                        state: task.current_roby_task_state,
                        started_since: task.start_event.last&.time,
                        arguments: marshal_task_arguments(channel, task.arguments)
                    )
                end

                # Convert a {Roby::TaskArguments}
                #
                # @param [Channel] channel
                # @param [Roby::TaskArguments] arguments
                # @return [Hash]
                def self.marshal_task_arguments(channel, arguments)
                    arguments.assigned_arguments.transform_values do
                        channel.marshal_filter_object(_1)
                    end
                end

                # Convert a {Exception}
                #
                # @param [Channel] channel
                # @param [Exception] exception
                # @return [Error]
                def self.marshal_exception(_channel, exception)
                    message = PP.pp(exception, +"").chomp
                    Error.new(
                        class_name: exception.class.name, message: message,
                        backtrace: exception.backtrace || []
                    )
                end

                # Convert a {ExecutionException}
                def self.marshal_execution_exception(channel, execution_exception)
                    exception = execution_exception.exception
                    if exception.respond_to?(:failed_task) &&
                       (failed_task = exception.failed_task)
                        marshalled_failed_task =
                            channel.marshal_filter_object(failed_task)
                    end

                    ExecutionException.new(
                        exception: marshal_exception(channel, exception),
                        failed_task: marshalled_failed_task,
                        involved_tasks: channel.marshal_filter_object(
                            execution_exception.each_involved_task.to_a
                        )
                    )
                end

                # Converts a {DelayedArgumentFromState}
                def self.marshal_delayed_argument_from_state(_channel, delayed_arg)
                    object =
                        case delayed_arg.__object__
                        when Conf
                            :Conf
                        when State
                            :State
                        else
                            delayed_arg.__object__.to_s
                        end

                    DelayedArgumentFromState.new(
                        object: object, path: delayed_arg.__methods__
                    )
                end

                StructObject = Struct.new :klass, :contents, keyword_init: true

                # Generic path to marshal a struct
                def self.marshal_struct_generic(channel, object)
                    contents = object.to_h.transform_values do |v|
                        channel.marshal_filter_object(v)
                    end
                    StructObject.new(klass: object.class.name, contents: contents)
                end

                def self.unmarshal_object(channel, object)
                    case object
                    when Array
                        object.map { unmarshal_object(channel, _1) }
                    when Hash
                        object.transform_values { unmarshal_object(channel, _1) }
                    when StructObject
                        unmarshal_struct_generic(channel, object)
                    else
                        object
                    end
                end

                def self.unmarshal_struct_generic(channel, object)
                    o = channel.resolve_struct(object).new
                    object.contents.each do |k, v|
                        o[k] = unmarshal_object(channel, v)
                    end
                    o
                end
            end
        end
    end
end
