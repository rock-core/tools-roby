module Roby
    module Coordination
        module Models
            # A representation of an event on the execution context's task
            class Event
                # @return [Coordination::Models::Task] The task this event is defined on
                attr_reader :task
                # @return [Symbol] the event's symbol
                attr_reader :symbol

                def initialize(task, symbol)
                    @task, @symbol = task, symbol.to_sym
                end

                # @return [Coordination::Base::Event]
                def new(execution_context)
                    Coordination::Event.new(execution_context, self)
                end

                def to_s; "#{task_model}.#{symbol}_event" end
            end
        end
    end
end

