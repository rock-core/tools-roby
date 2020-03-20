# frozen_string_literal: true

module Roby
    module Models
        # Model-level API for task events
        module TaskEvent
            include MetaRuby::ModelAsClass

            # The task model this event is defined on
            # @return [Model<Task>]
            attr_accessor :task_model

            # If the event model defines a controlable event
            # By default, an event is controlable if the model
            # responds to #call
            def controlable?
                respond_to?(:call)
            end

            # Called by Task.update_terminal_flag to update the flag
            attr_predicate :terminal?, true

            # @return [Symbol] the event name
            attr_accessor :symbol

            def setup_submodel(
                submodel, task_model: nil, symbol: nil, command: false,
                terminal: false, **options, &block
            )
                super(submodel, options, &block)
                submodel.task_model = task_model
                submodel.symbol     = symbol
                submodel.terminal   = terminal

                if command
                    if command.respond_to?(:call)
                        # check that the supplied command handler can take two arguments
                        check_arity(command, 2, strict: true)
                        submodel.singleton_class.class_eval do
                            define_method(:call, &command)
                        end
                    else
                        submodel.singleton_class.class_eval do
                            def call(task, context) # :nodoc:
                                task.event(symbol).emit(*context)
                            end
                        end
                    end
                end

                submodel
            end

            # @return [TaskEventGeneratorMatcher] returns an object that allows
            #   to match all generators of this type
            def match
                Queries::TaskEventGeneratorMatcher.new(task_model.match, symbol.to_s)
            end

            # @return [TaskEventGeneratorMatcher] returns an object that allows
            #   to match all generators of this type, as well as any generator
            #   that is forwarded to it
            def generalized_match
                Queries::TaskEventGeneratorMatcher
                    .new(task_model.match, symbol.to_s)
                    .generalized
            end
        end
    end
end
