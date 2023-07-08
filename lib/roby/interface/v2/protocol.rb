# frozen_string_literal: true

module Roby
    module Interface
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
            end

            ActionArgument = Struct.new(
                :name, :doc, :required, :default, :example, keyword_init: true
            ) do
                def required?
                    required
                end
            end

            Task = Struct.new(:id, :model, :arguments, keyword_init: true)
            Error = Struct.new(:class_name, :message, :backtrace, keyword_init: true)

            class VoidClass; end
            Void = VoidClass.new.freeze

            @marshallers = {}

            def self.allow_classes(*classes)
                add_marshaller(*classes) { _2 }
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
                    Command
                )

                protocol.add_marshaller(
                    Actions::Models::Action, &method(:marshal_action_model)
                )
                protocol.add_marshaller(Actions::Action, &method(:marshal_action))
                protocol.add_marshaller(Roby::Task, &method(:marshal_task))
                protocol.add_marshaller(Actions::Models::Action::VoidClass) { Void }
                protocol.add_marshaller(::Exception, &method(:marshal_exception))
                protocol.add_marshaller(
                    Roby::ExecutionException, &method(:marshal_execution_exception)
                )
            end

            # Configure channel marshalling to convert Roby classes into their
            # protocol equivalent
            #
            # @param [Channel] channel
            def self.setup_channel(channel)
                each_marshaller { |klass, block| channel.add_marshaller(klass, &block) }
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
                arguments =
                    action.arguments.map { marshal_action_argument_model(channel, _1) }
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
                message = PP.pp(exception, +"")
                Error.new(
                    class_name: exception.class.name, message: message,
                    backtrace: exception.backtrace
                )
            end
        end
    end
end
