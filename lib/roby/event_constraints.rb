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
        # Module that defines the unbound task predicate methods that are
        # added to the Symbol class
        module UnboundPredicateSupport
            # Returns an UnboundTaskPredicate that will be true if the generator
            # represented by this symbol has emitted at least once.
            #
            # In its simplest form,
            #
            #   :blocked.happened?
            #
            # will be true when evaluated on a task whose +blocked+ event has
            # emitted at least once
            def happened?
                to_unbound_task_predicate
            end

            # Protocol method. The unbound task predicate call always calls
            # #to_unbound_task_predicate on the arguments given to it.
            def to_unbound_task_predicate
                UnboundTaskPredicate::SingleEvent.new(self)
            end

            # Returns an UnboundTaskPredicate that will be true if the generator
            # represented by this symbol will never be emitted.
            #
            # In its simplest form,
            #
            #   :blocked.never
            #
            # will be true when evaluated on a task whose +blocked+ event has
            # not yet been emitted, and has been declared as unreachable
            def never
                to_unbound_task_predicate.never
            end

            # Returns an UnboundTaskPredicate that will be true if the generator
            # represented by this symbol has emitted at least once, and the
            # predicate represented by +other+ is true at the same time.
            #
            # In its simplest form,
            #
            #   :blocked.and(:updated)
            #
            # it will be true if the task on which it is applied has both
            # emitted :blocked and :updated at least once.
            def and(other)
                to_unbound_task_predicate.
                    and(other.to_unbound_task_predicate)
            end

            # Returns an UnboundTaskPredicate that will be true if the generator
            # represented by this symbol has emitted at least once, or the
            # predicate represented by +other+ is true.
            #
            # In its simplest form,
            #
            #   :blocked.or(:updated)
            #
            # it will be true if the task on which it is applied has either
            # emitted :blocked, or emitted :updated, or both.
            def or(other)
                to_unbound_task_predicate.
                    or(other.to_unbound_task_predicate)
            end

            # Returns an UnboundTaskPredicate that will be true if the generator
            # represented by this symbol and the generator represented by
            # +other+ (as a symbol) have emitted in sequence, i.e. if both
            # +self+ and +other+ have emitted at least once, and if the last
            # event e0 emitted by +self+ and the last event e1 emitted by
            # +other+ match
            #
            #     e0.time < e1.time
            #
            # Unlike +and+, +or+ and +negate+, this only works on single events
            # (i.e. it cannot be applied on other predicates)
            def followed_by(other)
                to_unbound_task_predicate.
                    followed_by(other.to_unbound_task_predicate)
            end

            # Returns an UnboundTaskPredicate that will be true if the generator
            # represented by this symbol and the generator represented by
            # +other+ (as a symbol) have not emitted in sequence, i.e. if +self+
            # has emitted at least once, and either +other+ has not emitted or
            # +other+ has emitted and the last event e0 emitted by +self+ and
            # the last event e1 emitted by +other+ do not match
            #
            #     e0.time < e1.time
            #
            # Unlike +and+, +or+ and +negate+, this only works on single events
            # (i.e. it cannot be applied on other predicates)
            def not_followed_by(other)
                to_unbound_task_predicate.
                    not_followed_by(other.to_unbound_task_predicate)
            end

            # Returns an UnboundTaskPredicate that will be true if the generator
            # represented by +self+ has never emitted
            def negate
                to_unbound_task_predicate.negate
            end
        end
        ::Symbol.include UnboundPredicateSupport

        class ::FalseClass
            # Returns an UnboundTaskPredicate object that will always evaluate
            # to false
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

            # Returns a predicate that is true if both +self+ and
            # +other_predicate+ are true.
            #
            # Because of the "and" semantic, the predicate is static if one of
            # the two predicates is false and static, or if both predicates
            # are static.
            def and(other_predicate)
                if self == other_predicate then self
                elsif other_predicate.kind_of?(UnboundTaskPredicate::False)
                    other_predicate
                else
                    And.new(self, other_predicate)
                end
            end

            # Returns a predicate that is true if either or both of +self+ and
            # +other_predicate+ are true.
            #
            # Because of the "or" semantic, the predicate is static if one of
            # the two predicates are true and static, or if both predicates
            # are static.
            def or(other_predicate)
                if self == other_predicate then self
                elsif other_predicate.kind_of?(UnboundTaskPredicate::False)
                    self
                else
                    Or.new(self, other_predicate)
                end
            end

            # Returns a predicate that is the negation of +self+
            #
            # Because of the "not" semantic, the predicate is static if +self+
            # is static.
            def negate
                Negate.new(self)
            end

            # Returns an Explanation object that explains why +self+ is true.
            # Note that it is valid only if evaluate(task) actually returned
            # true (it will silently return an invalid explanation if
            # evaluate(task) returns false).
            def explain_true(task); nil end

            # Returns an Explanation object that explains why +self+ is false.
            # Note that it is valid only if evaluate(task) actually returned
            # false (it will silently return an invalid explanation if
            # evaluate(task) returns true).
            def explain_false(task); nil end

            # Returns an Explanation object that explains why +self+ will not
            # change its value anymore.
            #
            # Note that it is valid only if static?(task) actually returned
            # true (it will silently return an invalid explanation otherwise)
            def explain_static(task)
            end

            def pretty_print(pp)
                pp.text to_s
            end

            # See #compile.
            #
            # Objects of this class hold the compiled predicate used for
            # evaluation
            class CompiledPredicate
                def marshal_dump; nil end
                def marshal_load(obj); nil end
            end

            # Predicates are first represented as an AST using the subclasses of
            # UnboundTaskPredicate, but are then compiled into code before being
            # evaluated (for performance reasons).
            #
            # This is the main call that performs this compilation
            def compile
                prelude = required_events.map do |event_name|
                    "    task_event_#{event_name} = task.event(:#{event_name})\n" +
                    "    task_#{event_name} = task_event_#{event_name}.last"
                end.join("\n")

                compiled_predicate = CompiledPredicate.new
                eval <<-END, binding, __FILE__, __LINE__+1
def compiled_predicate.evaluate(task)
#{prelude}
    #{code}
end
                END
                @compiled_predicate = compiled_predicate
            end

            # Evaluates this predicate on +task+. It returns either true or
            # false.
            def evaluate(task)
                compile if !@compiled_predicate || !@compiled_predicate.respond_to?(:evaluate)
                @compiled_predicate.evaluate(task)
            end
        end

        # An explanation for a given predicate value. +predicate+ is the
        # predicate, +elements+ the explanations for +predicate+ having reached
        # the value.
        #
        # +elements+ is an array of Event and EventGenerator instances. 
        #
        # If an Event is stored there, the explanation is that this event has
        # been emitted.
        #
        # If an EventGenerator is stored there, the reason depends on +value+.
        # If +value+ is nil (static), the reason is that the generator is
        # unreachable. If +value+ is false (not emitted), it is that the
        # generator did not emit.
        class Explanation
            # Representation of what is being explained. It is true if it is
            # explaining why a predicate is true, false if it is explaining why
            # it is false and nil for static.
            attr_accessor :value
            # The predicate that we are providing an explanation for
            attr_reader :predicate
            # The elements of explanation
            attr_reader :elements

            def simple?
                elements.size == 1 && !elements.first.kind_of?(Explanation)
            end

            def initialize(value, predicate, elements)
                @value, @predicate, @elements = value, predicate, elements
            end

            def pretty_print(pp)
                if value == false
                    predicate.pretty_print(pp)
                    pp.text " is false"
                elsif value == true
                    predicate.pretty_print(pp)
                    pp.text " is true"
                elsif value == nil
                    pp.text "the value of "
                    predicate.pretty_print(pp)
                    pp.text " will not change anymore"
                end

                pp.nest(2) do
                    elements.each do |explanation|
                        pp.breakable
                        case explanation
                        when Event
                            pp.text "the following event has been emitted "
                        when EventGenerator
                            if value == nil
                                pp.text "the following event is unreachable "
                            elsif value == true
                                pp.text "the following event is reachable, but has not been emitted "
                            else
                                pp.text "the following event has been emitted "
                            end
                        end

                        explanation.pretty_print(pp)
                        case explanation
                        when Event
                            sources = explanation.all_sources
                            if !sources.empty?
                                pp.breakable
                                pp.text "The emission was caused by the following events"
                                sources.each do |ev|
                                    pp.breakable
                                    pp.text "< "
                                    ev.pretty_print(pp, false)
                                end
                            end

                        when EventGenerator
                            if value == nil && explanation.unreachability_reason
                                pp.breakable
                                pp.text "The unreachability was caused by "
                                pp.nest(2) do
                                    pp.breakable
                                    explanation.unreachability_reason.pretty_print(pp)
                                end
                            end
                        else
                            explanation.pretty_print(pp)
                        end
                        pp.breakable
                    end
                end
            end
        end

        # Representation of a predicate that is always false
        class UnboundTaskPredicate::False < UnboundTaskPredicate
            def required_events; Set.new end
            def explain_true(task); Hash.new end
            def explain_false(task); Hash.new end
            def explain_static(task); Hash.new end
            def evaluate(task); false end
            def static?(task); true end
            def to_s; "false" end

            def ==(pred); pred.kind_of?(False) end

            def code
                "false"
            end

            def or(pred); pred end
            def and(pred); self end
        end

        # Representation of predicates UnboundPredicateSupport#negate and
        # UnboundTaskPredicate#negate
        #
        # See documentation from UnboundTaskPredicate
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

        # Representation of UnboundPredicateSupport#never
        #
        # See documentation from UnboundPredicateSupport
        class UnboundTaskPredicate::Never < UnboundTaskPredicate
            attr_reader :predicate
            def initialize(pred)
                if !pred.kind_of?(UnboundTaskPredicate::SingleEvent)
                    raise ArgumentError, "can only create a Never predicate on top of a SingleEvent"
                end

                @predicate = pred
            end

            def ==(pred); pred.kind_of?(Never) && pred.predicate == predicate end

            def explain_true(task)
                return if !evaluate(task)
                predicate.explain_static(task)
            end
            def explain_false(task)
                return if evaluate(task)
                if predicate.evaluate(task)
                    predicate.explain_true(task)
                elsif !predicate.static?(task)
                    explanation = predicate.explain_false(task)
                    explanation.value = true
                    explanation
                end
            end
            def explain_static(task)
                if predicate.evaluate(task)
                    predicate.explain_true(task)
                else
                    predicate.explain_static(task)
                end
            end

            def required_events; predicate.required_events end
            def code
                "(!task_#{predicate.event_name} && task_event_#{predicate.event_name}.unreachable?)"
            end
            def static?(task)
                evaluate(task) || predicate.static?(task)
            end
            def to_s; "never(#{predicate})" end
        end

        # Representation of a binary combination of predicates that is
        # commutative. It is used to simplify expressions, especially for
        # explanations.
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

        # Representation of UnboundPredicateSupport#and and
        # UnboundTaskPredicate#and
        #
        # See documentation from UnboundTaskPredicate
        class UnboundTaskPredicate::And < UnboundTaskPredicate::BinaryCommutativePredicate
            def code
                "(#{predicates[0].code}) && (#{predicates[1].code})"
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

            def static?(task)
                static0 = predicates[0].static?(task)
                static1 = predicates[1].static?(task)
                static0 && static1 ||
                    (static0 && !predicates[0].evaluate(task) ||
                     static1 && !predicates[1].evaluate(task))
            end

            def explain_static(task)
                static0 = predicates[0].static?(task)
                static1 = predicates[1].static?(task)
                if static0 && static1
                    super(task)
                elsif static0 && !predicates[0].evaluate(task)
                    predicates[0].explain_static(task)
                elsif static1 && !predicates[1].evaluate(task)
                    predicates[1].explain_static(task)
                end
            end

            def to_s; "(#{predicates[0]}) && (#{predicates[1]})" end
        end

        # Representation of UnboundPredicateSupport#or and
        # UnboundTaskPredicate#or
        #
        # See documentation from UnboundTaskPredicate
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
                    result
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

        # Representation of UnboundPredicateSupport#followed_by
        #
        # See documentation from UnboundTaskPredicate
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

        # Representation of UnboundPredicateSupport#not_followed_by
        #
        # See documentation from UnboundTaskPredicate
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

        # Subclass of UnboundTaskPredicate to handle single event generators
        #
        # This is the class that is e.g. returned by
        # UnboundPredicateSupport#to_unbound_task_predicate
        class UnboundTaskPredicate::SingleEvent < UnboundTaskPredicate
            # The generator name as a symbol
            attr_reader :event_name
            # The set of events required to compute this predicate. This is used
            # by UnboundTaskPredicate#compile
            attr_reader :required_events

            def initialize(event_name)
                @event_name = event_name
                @required_events = [event_name].to_set
                super()
            end

            def ==(pred); pred.kind_of?(SingleEvent) && pred.event_name == event_name end

            # Code generation to create the overall evaluated predicate
            def code
                "!!task_#{event_name}"
            end

            # Returns an Explanation object that explains why +self+ is true.
            # Note that it is valid only if evaluate(task) actually returned
            # true (it will silently return an invalid explanation if
            # evaluate(task) returns false).
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

