
module Roby
    class StateSpace
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

		result.on { result.reset }
		def result.or(spec); DeltaEvent.or(spec, self) end
		events.each { |ev| result << ev }
		result
	    else
		events.first
	    end
	end
    end

    class DeltaEvent < EventGenerator
	def self.poll
	    for ev in Roby.plan.free_events
		if ev.kind_of?(DeltaEvent)
		    ev.poll
		end
	    end
	end

	@@event_types = Hash.new
	def self.event_types; @@event_types end
	def self.register_as(name)
	    event_types[name] = self
	end

	def initialize
	    super
	    @cumulative = 0
	end

	attr_reader   :last_value
	attr_accessor :threshold

	def reset
	    @last_value = read
	    @cumulative = 0
	end

	def self.or(spec, base_event)
	    new = State.on_delta(spec)
	    result = OrGenerator.new
	    result << base_event
	    result << new
	    result.on { result.reset }
	    def result.or(spec); DeltaEvent.or(spec, self) end
	    result
	end

	def or(spec)
	    DeltaEvent.or(spec, self)
	end

	def poll
	    if !has_sample?
		return
	    elsif !last_value
		@last_value = read
	    else
		@cumulative += delta.abs
		if @cumulative >= threshold
		    reset
		    emit(last_value)
		else
		    @last_value = read
		end
	    end
	end
    end
    Roby::Control.each_cycle(&DeltaEvent.method(:poll))

    class TimeDeltaEvent < DeltaEvent
	register_as :t
	def has_sample?; true end
	def delta; Time.now - last_value end
	def read;  Time.now end
    end

    class YawDeltaEvent < DeltaEvent
	register_as :yaw
	def has_sample?; State.pos? end
	def delta; State.pos.yaw - last_value end
	def read;  State.pos.yaw end
    end

    class PosDeltaEvent < DeltaEvent
	register_as :d
	def has_sample?; State.pos? end
	def delta; State.pos.distance(last_value) end
	def read;  State.pos.dup end
    end
end




