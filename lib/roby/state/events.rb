
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
        #   Roby.state.on_delta :d => 10, :t => 20
        #
        # will emit everytime the robot moves more than 10 meters AND more than
        # 20 seconds have elapsed.
        #
        # If more than once specification is given, the resulting event is
        # combined with the & operator. This can be changed by setting the :or
        # option to 'true'.
        #
        #   Roby.state.on_delta :d => 10, :t => 20, :or => true
        #
        # See DeltaEvent and its subclasses.
	def on_delta(spec)
	    or_aggregate = spec.delete(:or)

	    events = spec.map do |name, value|
		unless klass = DeltaEvent.event_types[name]
		    raise "unknown delta type #{name}. Known types are #{DeltaEvent.event_types.keys}"
		end
		
		ev    = klass.new
		ev.threshold = value
		ev
	    end

	    if events.size > 1
		result = if or_aggregate then OrGenerator.new
			 else AndGenerator.new
			 end

		result.on { |ev| result.reset }
		def result.or(spec); DeltaEvent.or(spec, self) end
		events.each { |ev| result << ev }
		result
	    else
		events.first
	    end
	end

        # Returns an event which emits when the given state is reached.
        # For now, the following state variables are available:
        # +t+:: time as a Time object
        #
        # See TimePointEvent
        def at(options)
            options = validate_options options, :t => nil
            if time = options[:t]
                TimePointEvent.new(time)
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
    Roby::ExecutionEngine.add_propagation_handler(Roby.method(:poll_state_events))

    # A state event is an event which emits when some parameters over the state
    # are reached. See DeltaEvent and TimePointEvent.
    class StateEvent < EventGenerator
        def initialize(*args, &block)
            @disabled = nil
            super
        end

        # True if this event is currently active
        def enabled?; !@disabled end
        # True if this event is currently disabled
        def disabled?; @disabled end
        # Call to reenable this event. If +reset+ is true, the event is reset
        # at the same time.
        def enable(reset = true)
            @disabled = false
            self.reset if reset
        end
        # Call to disable this event. When the state events are disabled, they
        # will no more emit.
        def disable; @disabled = true end
    end

    # This event emits itself when the specified time is reached
    class TimePointEvent < StateEvent
        # Time at which this event should emit himself
        attr_reader :time

        # Creates an event which will emit when +time+ is reached
        def initialize(time)
            @time = time
            super
        end

        # Called at each cycle by Roby.poll_state_events
        def poll # :nodoc:
            if !happened? && Time.now >= time
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
	@@event_types = Hash.new
        # The set of event types which 
	def self.event_types; @@event_types end
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
        #   Roby.state.on_delta :t => 10
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
	end

	def self.or(spec, base_event)
	    new = State.on_delta(spec)
	    result = OrGenerator.new
	    result << base_event
	    result << new
	    result.on { |ev| result.reset }
	    def result.or(spec); DeltaEvent.or(spec, self) end
	    result
	end

	def or(spec)
	    DeltaEvent.or(spec, self)
	end

        # Called at each cycle by Roby.poll_state_events
	def poll # :nodoc:
	    if !has_sample?
		return
	    elsif !last_value
		@last_value = read
	    else
		if delta.abs >= threshold
		    reset
		    emit(last_value)
		end
	    end
	end
    end

    # An event which emits at a given period (delta in time)
    class TimeDeltaEvent < DeltaEvent
	register_as :t
        # Always true, as we can always measure time
	def has_sample?; true end
        # Returns how much time elapsed since the last emission
	def delta; Time.now - last_value end
        # Returns the current time
	def read;  Time.now end
    end

    # An event which emits everytime the robot heading moves more than a given
    # angle (in radians)
    class YawDeltaEvent < DeltaEvent
	register_as :yaw
        # True if State.pos is set
	def has_sample?; State.pos? end
        # Returns the variation in heading since the last emission (in radians)
	def delta; State.pos.yaw - last_value end
        # Returns the current heading position (in radians)
	def read;  State.pos.yaw end
    end

    # An event which emits everytime the robot moves more than a given
    # distance.
    class PosDeltaEvent < DeltaEvent
	register_as :d
        # True if State.pos is set
	def has_sample?; State.pos? end
        # Returns the distance this the position at the last emission
	def delta; State.pos.distance(last_value) end
        # Returns the current position
	def read;  State.pos.dup end
    end
end




