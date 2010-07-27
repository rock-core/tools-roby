module Roby
    # This namespace contains predicates that allow to specify logic ordering
    # constraints between events. The predicate objects can then be evaluated
    # (return true/false), and can tell whether their value may change in the
    # future.
    #
    # Moreover, for all three states (true, false, and static), the predicates
    # can explain which events and/or generators explain this state of the
    # predicate.
    #
    # For instance,
    #
    #   pred = :intermediate.to_unbound_task_predicate
    #
    # is a predicate that will return true if the intermediate event of the task
    # it represents has already been emitted, and false otherwise.
    #
    #   pred.evaluate(task) => true or false
    #
    # If task.intermediate? is true (the event has been emitted), then
    #
    #   pred.explain_true(task)
    #
    # will return an Explanation instance where +elements+ ==
    # [pred.intermediate_event.last] (the Event instance that has been emitted).
    #
    # However, if the event is not yet emitted then, 
    #
    #   pred.explain_false(task) => #<Explanation @elements=[pred.intermediate_event]>
    #
    # i.e. the reason is that intermediate_event has not been emitted.
    #
    # Finally, if intermediate has never been emitted and the task is finished
    # (let's say because success has been emitted), the intermediate event
    # cannot be emitted anymore. In this case,
    #
    #   pred.static?(task) => true
    #   pred.evaluate(task) => false
    #   pred.explain_static(task) => #<Explanation @elements=[task.event(:success)]>
    #
    module EventConstraints
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

            def never
                to_unbound_task_predicate.never
            end

            unbound_temporal_binary_predicate :and
            unbound_temporal_binary_predicate :or
            unbound_temporal_binary_predicate :followed_by
            unbound_temporal_binary_predicate :not_followed_by
            unbound_temporal_binary_predicate :negate
        end
        ::Symbol.include UnboundPredicateSupport

        class ::FalseClass
            def to_unbound_task_predicate
                Roby::EventConstraints::UnboundTaskPredicate::False.new
            end
        end

        # Represents a temporal logic predicate that applies on the internal
        # events of a single task. As the events are represented by their name,
        # the predicate can be reused to be applied on different tasks.
        class UnboundTaskPredicate
            def to_unbound_task_predicate
                self
            end

            def and(other_predicate)
                if self == other_predicate then self
                else
                    And.new(self, other_predicate)
                end
            end

            def or(other_predicate)
                if self == other_predicate then self
                elsif other_predicate.kind_of?(UnboundTaskPredicate::False)
                    self
                else
                    Or.new(self, other_predicate)
                end
            end

            def negate
                Negate.new(self)
            end

            def explain_true(task); nil end

            def explain_false(task); nil end

            def explain_unreachability(task)
                explanation = explain_false(task)
                explanation.to_unreachability
                explanation
            end

            def pretty_print(pp)
                pp.text to_s
            end

            class CompiledPredicate
                def marshal_dump; nil end
                def marshal_load(obj); nil end
            end

            def compile
                prelude = required_events.map do |event_name|
                    "    task_event_#{event_name} = task.event(:#{event_name})\n" +
                    "    task_#{event_name} = task_event_#{event_name}.last"
                end.join("\n")

                compiled_predicate = CompiledPredicate.new
                eval <<-END
def compiled_predicate.evaluate(task)
#{prelude}
    #{code}
end
                END
                @compiled_predicate = compiled_predicate
            end

            def evaluate(task)
                compile if !@compiled_predicate || !@compiled_predicate.respond_to?(:evaluate)
                @compiled_predicate.evaluate(task)
            end
        end

        # An explanation for a given predicate value. +predicate+ is the
        # predicate, +events+ the involved events as a set of
        # Event and EventGenerator instances. 
        #
        # In the first case, the value of +predicate+ has to be explained by
        # the event emission. In the second case, the value of +predicate+
        # has to be explained because the event generator did not emit an
        # event.
        class Explanation
            attr_reader :value
            attr_reader :predicate
            attr_reader :elements

            def simple?
                elements.size == 1 && !elements.first.kind_of?(Explanation)
            end

            def initialize(value, predicate, elements)
                @value, @predicate, @elements = value, predicate, elements
            end

            def pretty_print(pp)
                predicate.pretty_print(pp)
                if value == false
                    pp.text " is false"
                elsif value == true
                    pp.text " is true"
                elsif value == nil
                    pp.text " will never be true"
                end
                pp.breakable

                pp.nest(2) do
                    elements.each do |explanation|
                        explanation.pretty_print(pp)
                        case explanation
                        when Event
                            pp.text " has been emitted"
                        when EventGenerator
                            if value == nil
                                if explanation.unreachability_reason
                                    pp.text " is unreachable because of"
                                    pp.breakable
                                    pp.text "  "
                                    explanation.unreachability_reason.pretty_print(pp)
                                else
                                    pp.text " is unreachable"
                                end
                            else
                                pp.text " has not been emitted"
                            end
                        else
                            explanation.pretty_print(pp)
                        end
                        pp.breakable
                    end
                end
            end
        end

        class UnboundTaskPredicate::False < UnboundTaskPredicate
            def required_events; Set.new end
            def explain_true(task); Hash.new end
            def explain_false(task); Hash.new end
            def explain_static(task); Hash.new end
            def evaluate(task); false end
            def static?(task); true end
            def to_s; "false" end

            def ==(pred); pred.kind_of?(False) end

            def or(pred); pred end
            def and(pred); self end
        end

        class UnboundTaskPredicate::Negate < UnboundTaskPredicate
            attr_reader :predicate
            def initialize(pred)
                @predicate = pred
            end

            def ==(pred); pred.kind_of?(Negate) && pred.predicate == predicate end

            def explain_true(task);  predicate.explain_false(task) end
            def explain_false(task); predicate.explain_true(task)  end
            def explain_static(task); predicate.explain_static(task) end

            def required_events; predicate.required_events end
            def code
                "!(#{predicate.code})"
            end
            def static?(task); predicate.static?(task) end
            def to_s; "!#{predicate}" end
        end

        class UnboundTaskPredicate::Never < UnboundTaskPredicate
            attr_reader :predicate
            def initialize(pred)
                if !pred.kind_of?(UnboundTaskPredicate::SingleEvent)
                    raise ArgumentError, "can only create a Never predicate on top of a SingleEvent"
                end

                @predicate = pred
            end

            def ==(pred); pred.kind_of?(Never) && pred.predicate == predicate end

            def explain_true(task);  predicate.explain_static(task) end
            def explain_false(task); predicate.explain_true(task)  end
            def explain_static(task); predicate.explain_static(task) end

            def required_events; predicate.required_events end
            def code
                "(!task_#{predicate.event_name} && task_event_#{predicate.event_name}.unreachable?)"
            end
            def static?(task); predicate.static?(task) end
            def to_s; "never(#{predicate})" end
        end

        class UnboundTaskPredicate::BinaryCommutativePredicate < UnboundTaskPredicate
            attr_reader :predicates
            def initialize(left, right)
                @predicates = [left, right]
            end

            def required_events; predicates[0].required_events | predicates[1].required_events end

            def ==(pred)
                pred.kind_of?(self.class) &&
                    ((predicates[0] == pred.predicates[0] && predicates[1] == pred.predicates[1]) ||
                    (predicates[0] == pred.predicates[1] && predicates[1] == pred.predicates[0]))
            end

            def explain_true(task)
                return if !evaluate(task)

                reason0 = predicates[0].explain_true(task)
                reason1 = predicates[1].explain_true(task)
                if reason0 && reason1
                    Explanation.new(true, self, [reason0, reason1])
                else
                    reason0 || reason1
                end
            end
            def explain_false(task)
                return if evaluate(task)

                reason0 = predicates[0].explain_false(task)
                reason1 = predicates[1].explain_false(task)
                if reason0 && reason1
                    Explanation.new(false, self, [reason0, reason1])
                else
                    reason0 || reason1
                end
            end
            def explain_static(task)
                return if !static?(task)

                reason0 = predicates[0].explain_static(task)
                reason1 = predicates[1].explain_static(task)
                if reason0 && reason1
                    Explanation.new(nil, self, [reason0, reason1])
                else
                    reason0 || reason1
                end
            end

            def has_atomic_predicate?(pred)
                pred = pred.to_unbound_task_predicate
                each_atomic_predicate do |p|
                    return(true) if p == pred
                end
                false
            end

            def each_atomic_predicate(&block)
                2.times do |i|
                    if predicates[i].kind_of?(self.class)
                        predicates[i].each_atomic_predicate(&block)
                    else
                        yield(predicates[i])
                    end
                end
            end
        end

        class UnboundTaskPredicate::And < UnboundTaskPredicate::BinaryCommutativePredicate
            def code
                "(#{predicates[0].code}) && (#{predicates[1].code})"
            end
            def static?(task)
                (predicates[0].static?(task) && predicates[1].static?(task))
            end

            def and(pred)
                pred = pred.to_unbound_task_predicate
                if pred.kind_of?(And)
                    # Only add predicates in +pred+ that are not already in
                    # +self+
                    result = self
                    pred.each_atomic_predicate do |predicate|
                        result = result.and(predicate)
                    end
                elsif has_atomic_predicate?(pred)
                    self
                else
                    super
                end
            end

            def explain_static(task)
                return if !static?(task)

                if predicates[0].evaluate(task)
                    reason0 = predicates[0].explain_static(task)
                    reason1 = predicates[1].explain_static(task)
                    if reason0 && reason1
                        Explanation.new(nil, self, [reason0, reason1])
                    else
                        reason0 || reason1
                    end
                else
                    predicates[0].explain_static(task)
                end
            end
            def to_s; "(#{predicates[0]}) && (#{predicates[1]})" end
        end

        class UnboundTaskPredicate::Or < UnboundTaskPredicate::BinaryCommutativePredicate
            def code
                "(#{predicates[0].code}) || (#{predicates[1].code})"
            end

            def or(pred)
                pred = pred.to_unbound_task_predicate
                if pred.kind_of?(Or)
                    # Only add predicates in +pred+ that are not already in
                    # +self+
                    result = self
                    pred.each_atomic_predicate do |predicate|
                        result = result.or(predicate)
                    end
                elsif has_atomic_predicate?(pred)
                    # Do not add +pred+ if it is already included in +self+
                    self
                else
                    super
                end
            end

            def static?(task)
                static0 = predicates[0].static?(task)
                static1 = predicates[1].static?(task)
                static0 && static1 ||
                    (static0 && predicates[0].evaluate(task) ||
                     static1 && predicates[1].evaluate(task))
            end

            def explain_static(task)
                static0 = predicates[0].static?(task)
                static1 = predicates[1].static?(task)
                if static0 && static1
                    super(task)
                elsif static0 && predicates[0].evaluate(task)
                    predicates[0].explain_static(task)
                elsif static1 && predicates[1].evaluate(task)
                    predicates[1].explain_static(task)
                end
            end
            def to_s; "(#{predicates[0]}) || (#{predicates[1]})" end
        end

        class UnboundTaskPredicate::FollowedBy < UnboundTaskPredicate::BinaryCommutativePredicate
            def explain_true(task)
                return if !evaluate(task)

                this_event  = task.event(predicates[0].event_name).last
                other_event = task.event(predicates[1].event_name).last
                Explanation.new(true, self, [this_event, other_event])
            end
            def explain_false(task)
                return if evaluate(task)

                this_generator  = task.event(predicates[0].event_name)
                other_generator = task.event(predicates[1].event_name)
                if !this_generator.last
                    Explanation.new(false, self, [this_generator])
                else
                    Explanation.new(false, self, [other_generator])
                end
            end
            def explain_static(task)
                return if !static?(task)

                if predicates[0].static?(task)
                    this_generator  = task.event(predicates[0].event_name)
                    if !predicates[0].evaluate(task) || evaluate(task)
                        Explanation.new(nil, self, [this_generator])
                    else # first event emitted, second event cannot be emitted (static)
                        other_generator = task.event(predicates[1].event_name)
                        Explanation.new(nil, self, [other_generator])
                    end
                else
                    other_generator = task.event(predicates[1].event_name)
                    Explanation.new(nil, self, [other_generator])
                end
            end
            def static?(task)
                event0 = task.event(predicates[0].event_name)
                event1 = task.event(predicates[1].event_name)

                if event0.unreachable?
                    (!predicates[0].evaluate(task) || # will stay false as pred[0] can't emit
                     evaluate(task) || # will stay true as pred[0] can't emit
                     predicates[1].static?(task))
                elsif event1.unreachable?
                    !evaluate(task)
                end
            end

            def code
                this_event  = predicates[0].event_name
                other_event = predicates[1].event_name
                "(task_#{this_event} && task_#{other_event} && task_#{other_event}.time > task_#{this_event}.time)"
            end
            def to_s; "#{predicates[0].event_name}.followed_by(#{predicates[1].event_name})" end
        end

        class UnboundTaskPredicate::NotFollowedBy < UnboundTaskPredicate::BinaryCommutativePredicate
            def explain_true(task)
                return if !evaluate(task)

                this_event  = task.event(predicates[0].event_name).last
                other_generator = task.event(predicates[1].event_name)
                other_generator = other_generator.last || other_generator
                Explanation.new(true, self, [this_event, other_generator])
            end
            def explain_false(task)
                return if evaluate(task)

                this_generator  = task.event(predicates[0].event_name)
                if !this_generator.last
                    Explanation.new(false, self, [this_generator])
                else
                    other_generator = task.event(predicates[1].event_name)
                    Explanation.new(false, self, [other_generator.last])
                end
            end
            def explain_static(task)
                return if !static?(task)

                if predicates[0].static?(task)
                    this_generator  = task.event(predicates[0].event_name)
                    if !predicates[0].evaluate(task) || !evaluate(task)
                        Explanation.new(nil, self, [this_generator])
                    else
                        other_generator = task.event(predicates[1].event_name)
                        Explanation.new(nil, self, [this_generator, other_generator])
                    end
                else
                    other_generator = task.event(predicates[1].event_name)
                    Explanation.new(nil, self, [other_generator])
                end
            end
            def static?(task)
                event0 = task.event(predicates[0].event_name)
                event1 = task.event(predicates[1].event_name)

                if event0.unreachable?
                    (!predicates[0].evaluate(task) || # stay false as first event can't emit
                     !evaluate(task) || # stay false as first event can't emit
                     predicates[1].static?(task))
                elsif event1.unreachable?
                    evaluate(task) # stays true as the second event cannot
                                   # appear after the first anymore
                end
            end

            def code
                this_event  = predicates[0].event_name
                other_event = predicates[1].event_name
                "(task_#{this_event} && (!task_#{other_event} || task_#{other_event}.time < task_#{this_event}.time))"
            end
            def to_s; "#{predicates[0].event_name}.not_followed_by(#{predicates[1].event_name})" end
        end

        class UnboundTaskPredicate::SingleEvent < UnboundTaskPredicate
            attr_reader :event_name
            attr_reader :required_events

            def initialize(event_name)
                @event_name = event_name
                @required_events = [event_name].to_set
                super()
            end

            def ==(pred); pred.kind_of?(SingleEvent) && pred.event_name == event_name end

            def code
                "!!task_#{event_name}"
            end

            def explain_true(task)
                if event = task.event(event_name).last
                    Explanation.new(true, self, [event])
                end
            end
            def explain_false(task)
                generator = task.event(event_name)
                if !generator.happened?
                    Explanation.new(false, self, [generator])
                end
            end
            def explain_static(task)
                event = task.event(event_name)
                if event.last
                    Explanation.new(true, self, [event.last])
                elsif event.unreachable?
                    Explanation.new(nil, self, [event])
                end
            end
            def static?(task)
                event = task.event(event_name)
                event.happened? || event.unreachable?
            end

            def never
                Never.new(self)
            end

            def not_followed_by(event)
                NotFollowedBy.new(self, event.to_unbound_task_predicate)
            end

            def followed_by(event)
                FollowedBy.new(self, event.to_unbound_task_predicate)
            end

            def to_s; "#{event_name}?" end
        end
    end
end

