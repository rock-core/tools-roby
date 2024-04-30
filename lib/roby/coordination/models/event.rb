# frozen_string_literal: true

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

                def ==(other)
                    other.kind_of?(self.class) &&
                        other.symbol == symbol &&
                        other.task == task
                end

                # When running in this event's state, forward this event to the
                # given root task event
                def forward_to(root_event)
                    unless root_event.task.respond_to?(:coordination_model)
                        raise NotRootEvent, "can only forward to a root event"
                    end

                    root_event.task.coordination_model.parse_names
                    root_event.task.coordination_model
                              .forward task, self, root_event
                end

                def to_s
                    "#{task}.#{symbol}_event"
                end
            end
        end
    end
end
