module Roby
    module TemporalLogic
        module UnboundPredicateSupport
            def happened?
                to_unbound_task_predicate
            end

            def to_unbound_task_predicate
                UnboundTaskPredicate::SingleEvent.new(self)
            end

            def self.unbound_temporal_binary_predicate(name)
                class_eval <<-END
def #{name}(other)
    to_unbound_task_predicate.
        #{name}(other.to_unbound_task_predicate)
end
                END
            end

            unbound_temporal_binary_predicate :and
            unbound_temporal_binary_predicate :or
            unbound_temporal_binary_predicate :followed_by
            unbound_temporal_binary_predicate :not_followed_by
            unbound_temporal_binary_predicate :negate
        end
        ::Symbol.include UnboundPredicateSupport

        # Represents a temporal logic predicate that applies on the internal
        # events of a single task. As the events are represented by their name,
        # the predicate can be reused to be applied on different tasks.
        class UnboundTaskPredicate
            attr_reader :required_events
            attr_reader :code

            def initialize(required_events, code)
                @required_events = required_events
                @code = code
            end

            def to_unbound_task_predicate
                self
            end

            def and(other_predicate)
                code = "(#{self.code}) && (#{other_predicate.code})"
                UnboundTaskPredicate.new(self.required_events | other_predicate.required_events, code)
            end

            def or(other_predicate)
                code = "(#{self.code}) || (#{other_predicate.code})"
                UnboundTaskPredicate.new(self.required_events | other_predicate.required_events, code)
            end

            def negate
                code = "!(#{self.code})"
                UnboundTaskPredicate.new(self.required_events, code)
            end

            def compile
                prelude = required_events.map do |event_name|
                    "    task_#{event_name} = task.event(:#{event_name}).last"
                end.join("\n")
                eval <<-END
def self.evaluate(task)
#{prelude}
    #{code}
end
                END
            end

            def evaluate(task)
                compile
                self.evaluate(task)
            end
        end

        class UnboundTaskPredicate::SingleEvent < UnboundTaskPredicate
            attr_reader :event_name

            def initialize(event_name)
                @event_name = event_name
                super([event_name].to_set, "")
            end

            def code
                "!!task_#{event_name}"
            end

            def not_followed_by(event)
                other_event =
                    if event.respond_to?(:event_name)
                        event.event_name
                    else event
                    end

                code = "(task_#{event_name} && (!task_#{other_event} || task_#{other_event}.time < task_#{event_name}.time))"
                UnboundTaskPredicate.new([event_name, other_event].to_set | self.required_events, code)
            end

            def followed_by(event)
                other_event =
                    if event.respond_to?(:event_name)
                        event.event_name
                    else event.to_sym
                    end

                code = "(task_#{event_name} && task_#{other_event} && task_#{other_event}.time > task_#{event_name}.time)"
                UnboundTaskPredicate.new([event_name, other_event].to_set | self.required_events, code)
            end
        end
    end
end

