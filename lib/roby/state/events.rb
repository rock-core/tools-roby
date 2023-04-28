# frozen_string_literal: true

module Roby
    class StateSpace
        # Create an event which will be emitted everytime some state parameters
        # vary more than the given deltas. The following state parameters are
        # available:
        # +t+:: time in seconds
        # +d+:: distance in meters
        # +yaw+:: heading in radians
        #
        # For instance:
        #   Roby.state.on_delta d: 10, t: 20
        #
        # will emit everytime the robot moves more than 10 meters AND more than
        # 20 seconds have elapsed.
        #
        # If more than once specification is given, the resulting event is
        # combined with the & operator. This can be changed by setting the :or
        # option to 'true'.
        #
        #   Roby.state.on_delta d: 10, t: 20, or: true
        #
        # See DeltaEvent and its subclasses.
        def on_delta(spec)
            or_aggregate = spec.delete(:or)

            events = spec.map do |name, value|
                unless klass = DeltaEvent.event_types[name]
                    raise "unknown delta type #{name}. Known types are #{DeltaEvent.event_types.keys}"
                end

                ev = klass.new
                ev.threshold = value
                ev
            end

            if events.size > 1
                result = if or_aggregate then OrGenerator.new
                         else
                             AndGenerator.new
                         end

                result.on { |ev| result.reset }
                def result.or(spec)
                    DeltaEvent.or(spec, self)
                end
                events.each { |ev| result << ev }
                result
            else
                events.first
            end
        end

        # Returns a state event that emits the first time the block returns true
        #
        # The block is given the value of the specified state value
        # +state_name+. For instance, with
        #
        #   event = State.position.trigger_when(:x) do |value|
        #       value > 23
        #   end
        #
        # +event+ will be emitted *once* if the X value of the position gets
        # greater than 23. One can also specify a reset condition with
        #
        #   State.position.reset_when(event, :x) do |value|
        #       value < 20
        #   end
        #
        def trigger_when(*state_path, &block)
            unless block_given?
                raise ArgumentError, "#trigger_when expects a block"
            end

            state_path.map!(&:to_s)
            StateConditionEvent.new(self, state_path, block)
        end

        # Installs a condition at which the event should be reset
        def reset_when(event, state_name = nil, &block)
            reset_event = trigger_when(state_name, &block)
            reset_event.add_causal_link event
            reset_event.armed = !event.armed?
            event.on { |ev| reset_event.reset }
            reset_event.on { |ev| event.reset }
            reset_event
        end

        # Returns an event which emits when the given state is reached.
        # For now, the following state variables are available:
        # +t+:: time as a Time object
        #
        # See TimePointEvent
        def at(options)
            options = validate_options options, t: nil
            if time = options[:t]
                trigger_when { Time.now >= time }
            end
        end
    end

    # Registered on the execution engines to call the #poll method of state
    # events
    def self.poll_state_events(plan) # :nodoc:
        for ev in plan.free_events
            if ev.kind_of?(StateEvent) && ev.enabled?
                ev.poll
            end
        end
    end
    Roby::ExecutionEngine.add_propagation_handler(description: "poll_state_events", type: :propagation, &Roby.method(:poll_state_events))

    # A state event is an event which emits when some parameters over the state
    # are reached. See DeltaEvent and TimePointEvent.
    class StateEvent < EventGenerator
        def initialize(*args, &block)
            @disabled = nil
            @armed = true
            super
        end

        # If true, this event will be emitted the next time its condition is
        # met, regardless of the fact that it has already been emitted or not
        #
        # Call #reset to set to true after an emission
        attr_predicate :armed?, true

        # After this call, the event will be emitted the next time its state
        # condition is met, regardless of the fact that it has already been
        # emitted or not
        #
        # See also #armed?
        def reset
            @armed = true
        end

        # True if this event is currently active
        def enabled?
            !@disabled
        end

        # True if this event is currently disabled
        def disabled?
            @disabled
        end

        # Call to reenable this event. If +reset+ is true, the event is reset
        # at the same time.
        def enable(reset = true)
            @disabled = false
            self.reset if reset
        end

        # Call to disable this event. When the state events are disabled, they
        # will no more emit.
        def disable
            @disabled = true
        end

        # Emit only if the event is armed
        def emit(*context) # :nodoc:
            if armed?
                begin
                    super
                ensure
                    @armed = false
                end
            end
        end
    end

    # Implementation of StateSpace#trigger_when
    class StateConditionEvent < StateEvent
        attr_reader :state_space, :variable_path, :condition

        def initialize(state_space = nil, variable_path = [], condition = nil)
            @state_space, @variable_path, @condition =
                state_space, variable_path, condition
            super(false)
        end

        def poll
            return unless armed?

            if !variable_path.empty?
                value = variable_path.inject(state_space) do |value, element|
                    result =
                        if value.respond_to?("#{element}?")
                            if value.send("#{element}?")
                                value.send(element)
                            end
                        elsif value.respond_to?(element)
                            value.send(element)
                        end

                    unless result
                        break
                    end

                    result
                end

                if value && condition.call(value)
                    emit
                end
            elsif condition.call
                emit
            end
        end
    end

    # Generic implementation of events which emit when a given delta is reached
    # in the state. Subclasses must implement the following methods:
    #
    # [<tt>#has_sample</tt>]
    #   must return true if the state variable can be read
    # [<tt>#delta</tt>]
    #   must return the delta between the current value and the
    #   value at the last emission (#last_value). The returned value
    #   must be comparable with #threshold.
    # [<tt>#read</tt>]
    #   must return the current value.
    class DeltaEvent < StateEvent
        @@event_types = {}
        # The set of event types which
        def self.event_types
            @@event_types
        end

        # Declare that the currently defined delta event has to be registered
        # as a +name+ option for StateSpace#on_delta. For instance, the TimeDeltaEvent
        # is registered by using
        #
        #   class TimeDeltaEvent < DeltaEvent
        #     register_as :t
        #   end
        #
        # which allows to use it with
        #
        #   Roby.state.on_delta t: 10
        def self.register_as(name)
            event_types[name] = self
        end

        # The last value for the considered state, the last time this event has
        # been emitted
        attr_reader   :last_value
        # A value expressing the delta in state for which the event should be
        # emitted.
        attr_accessor :threshold

        # Reset +last_value+ to the current value of the state variable,
        # making the event emit at current_value + threshold
        def reset
            @last_value = read
            super
        end

        def self.or(spec, base_event)
            new = State.on_delta(spec)
            result = OrGenerator.new
            result << base_event
            result << new
            result.on { |ev| result.reset }
            def result.or(spec)
                DeltaEvent.or(spec, self)
            end
            result
        end

        def or(spec)
            DeltaEvent.or(spec, self)
        end

        # Called at each cycle by Roby.poll_state_events
        def poll # :nodoc:
            if !has_sample?
                nil
            elsif !last_value
                @last_value = read
            elsif delta.abs >= threshold
                reset
                emit(last_value)
            end
        end
    end

    # An event which emits at a given period (delta in time)
    class TimeDeltaEvent < DeltaEvent
        register_as :t
        # Always true, as we can always measure time
        def has_sample?
            true
        end

        # Returns how much time elapsed since the last emission
        def delta
            Time.now - last_value
        end

        # Returns the current time
        def read
            Time.now
        end
    end

    # An event which emits everytime the robot heading moves more than a given
    # angle (in radians)
    class YawDeltaEvent < DeltaEvent
        register_as :yaw
        # True if State.pos is set
        def has_sample?
            State.pos?
        end

        # Returns the variation in heading since the last emission (in radians)
        def delta
            State.pos.yaw - last_value
        end

        # Returns the current heading position (in radians)
        def read
            State.pos.yaw
        end
    end

    # An event which emits everytime the robot moves more than a given
    # distance.
    class PosDeltaEvent < DeltaEvent
        register_as :d
        # True if State.pos is set
        def has_sample?
            State.pos?
        end

        # Returns the distance this the position at the last emission
        def delta
            State.pos.distance(last_value)
        end

        # Returns the current position
        def read
            State.pos.dup
        end
    end
end
