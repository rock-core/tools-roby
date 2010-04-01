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
            # An explanation for a given predicate value. +predicate+ is the
            # predicate, +events+ the involved events as a set of
            # Event and EventGenerator instances. 
            #
            # In the first case, the value of +predicate+ has to be explained by
            # the event emission. In the second case, the value of +predicate+
            # has to be explained because the event generator did not emit an
            # event.
            Explanation = Struct.new :value, :predicate, :events

            def to_unbound_task_predicate
                self
            end

            def and(other_predicate)
                And.new(self, other_predicate)
            end

            def or(other_predicate)
                Or.new(self, other_predicate)
            end

            def negate
                Negate.new(self)
            end

            def explain_true(task); nil end

            def explain_false(task); nil end

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

        class UnboundTaskPredicate::Negate < UnboundTaskPredicate
            attr_reader :predicate
            def initialize(pred)
                @predicate = pred
            end

            def explain_true(task);  predicate.explain_false(task) end
            def explain_false(task); predicate.explain_true(task)  end

            def required_events; predicate.required_events end
            def code
                "!(#{predicate.code})"
            end
        end

        class UnboundTaskPredicate::BinaryPredicate < UnboundTaskPredicate
            attr_reader :predicates
            def initialize(left, right)
                @predicates = [left, right]
            end
            def required_events; predicates[0].required_events | predicates[1].required_events end
        end

        class UnboundTaskPredicate::And < UnboundTaskPredicate::BinaryPredicate
            def code
                "(#{predicates[0].code}) && (#{predicates[1].code})"
            end
            def explain_true(task)
                reason0 = predicates[0].explain_true(task)
                reason1 = predicates[1].explain_true(task)
                reason0.merge(reason1)
            end
            def explain_false(task)
                reason0 = predicates[0].explain_false(task)
                reason1 = predicates[1].explain_false(task)
                reason0.merge(reason1)
            end
        end

        class UnboundTaskPredicate::Or < UnboundTaskPredicate::BinaryPredicate
            def explain_true(task)
                reason0 = predicates[0].explain_true(task)
                reason1 = predicates[1].explain_true(task)
                reason0.merge(reason1)
            end
            def explain_false(task)
                reason0 = predicates[0].explain_false(task)
                reason1 = predicates[1].explain_false(task)
                reason0.merge(reason1)
            end
            def code
                "(#{predicates[0].code}) || (#{predicates[1].code})"
            end
        end

        class UnboundTaskPredicate::FollowedBy < UnboundTaskPredicate::BinaryPredicate
            def explain_true(task)
                if evaluate(task)
                    this_event  = task.event(predicates[0].event_name).last
                    other_event = task.event(predicates[1].event_name).last
                    Hash[self => Explanation.new(true, self, [this_event, other_event])]
                else Hash.new
                end
            end
            def explain_false(task)
                if !evaluate(task)
                    this_generator  = task.event(predicates[0].event_name)
                    other_generator = task.event(predicates[1].event_name)
                    if !this_generator.last
                        Hash[self => Explanation.new(false, self, [this_generator])]
                    else
                        Hash[self => Explanation.new(false, self, [other_generator])]
                    end
                else Hash.new
                end
            end

            def code
                this_event  = predicates[0].event_name
                other_event = predicates[1].event_name
                "(task_#{this_event} && task_#{other_event} && task_#{other_event}.time > task_#{this_event}.time)"
            end
        end


        class UnboundTaskPredicate::NotFollowedBy < UnboundTaskPredicate::BinaryPredicate
            def explain_true(task)
                if evaluate(task)
                    this_event  = task.event(predicates[0].event_name).last
                    other_generator = task.event(predicates[1].event_name)
                    Hash[self => Explanation.new(true, self, [this_event, other_generator])]
                else Hash.new
                end
            end
            def explain_false(task)
                if !evaluate(task)
                    this_generator  = task.event(predicates[0].event_name)
                    other_generator = task.event(predicates[1].event_name)
                    if !this_generator.last
                        Hash[self => Explanation.new(false, self, [this_generator])]
                    else
                        Hash[self => Explanation.new(false, self, [other_generator.last])]
                    end
                else Hash.new
                end
            end
            def code
                this_event  = predicates[0].event_name
                other_event = predicates[1].event_name
                "(task_#{this_event} && (!task_#{other_event} || task_#{other_event}.time < task_#{this_event}.time))"
            end
        end

        class UnboundTaskPredicate::SingleEvent < UnboundTaskPredicate
            attr_reader :event_name
            def required_events; [event_name].to_set end

            def initialize(event_name)
                @event_name = event_name
                super()
            end

            def code
                "!!task_#{event_name}"
            end

            def explain_true(task)
                if event = task.event(event_name).last
                    Hash[self => Explanation.new(true, self, [event])]
                else Hash.new
                end
            end
            def explain_false(task)
                generator = task.event(event_name)
                if !generator.happened?
                    Hash[self => Explanation.new(false, self, [generator])]
                else Hash.new
                end
            end

            def not_followed_by(event)
                NotFollowedBy.new(self, event.to_unbound_task_predicate)
            end

            def followed_by(event)
                FollowedBy.new(self, event.to_unbound_task_predicate)
            end
        end
    end
end

