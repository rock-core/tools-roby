module Roby
    module Actions
        module Models
        module ExecutionContext
            # A representation of an event on the execution context's task
            class Event
                # @return [ExecutionContext::Task] The task this event is defined on
                attr_reader :task_model
                # @return [Symbol] the event's symbol
                attr_reader :symbol

                def initialize(task_model, symbol)
                    @task_model, @symbol = task_model, symbol.to_sym
                end

                # @return [Actions::ExecutionContext::Event]
                def new(execution_context)
                    Actions::ExecutionContext::Event.new(execution_context, self)
                end

                def to_s; "#{task_model}.#{symbol}_event" end
            end
        end
        end
    end
end


