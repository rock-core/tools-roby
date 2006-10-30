
module Roby
    class EventGenerator
	@@propagate = true
	def self.disable_propagation; @@propagate = false end
	def self.enable_propagation; @@propagate = true end
	def self.propagate?; @@propagate end

	@@propagation_id = 0

	# If we are currently in the propagation stage
	def self.gathering?; !!Thread.current[:propagation] end
	def self.source_event; Thread.current[:propagation_event] end
	def self.source_generator; Thread.current[:propagation_generator] end
	def self.propagation_id; Thread.current[:propagation_id] end

	# Begin a propagation stage
	def self.gather_propagation
	    raise "nested call to #gather_propagation" if gathering?
	    Thread.current[:propagation] = Hash.new { |h, k| h[k] = Array.new }

	    yield

	    return Thread.current[:propagation]
	ensure
	    Thread.current[:propagation] = nil
	end

	# returns the value returned by the block
	def self.propagation_context(source)
	    raise "not in a gathering context in #fire" unless gathering?
	    event, generator = source_event, source_generator

	    if source.kind_of?(Event)
		Thread.current[:propagation_event] = source
		Thread.current[:propagation_generator] = source.generator
	    else
		Thread.current[:propagation_event] = nil
		Thread.current[:propagation_generator] = source
	    end

	    yield Thread.current[:propagation]

	ensure
	    Thread.current[:propagation_event] = event
	    Thread.current[:propagation_generator] = generator
	end


	def self.add_signal_to_propagation(only_forward, event, signalled, context)
	    if event == signalled
		raise EventModelViolation.new(event.generator), "#{event.generator} is trying to signal itself"
	    elsif !only_forward && !event.generator.can_signal?(signalled) 
		# NOTE: the can_signal? test here is NOT redundant with the test in #on, 
		# since here we validate calls done in event handlers too
		raise EventModelViolation.new(event.generator), "trying to signal #{signalled} from #{event.generator}"
	    end

	    Thread.current[:propagation][signalled] << [only_forward, event, context]
	end

	# Calls its block in a #gather_propagation context and propagate events
	# that have been called and/or emitted by the block
	#
	# the block argument is the initial set of events: the events we should
	# consider as already emitted in the following propagation
	def self.propagate
	    return if !propagate?

	    Thread.current[:propagation_id] = (@@propagation_id += 1)

	    initial_set = []
	    next_step = gather_propagation do
		yield(initial_set)
	    end

	    # Problem with postponed: the object is included in already_seen while it
	    # has not been fired
	    already_seen = initial_set.to_set

	    while !next_step.empty?
		next_step = gather_propagation do
		    # Note that internal signalling does not need a #call
		    # method (hence the respond_to? check). The fact that the
		    # event can or cannot be fired is checked in #fire (using can_signal?)
		    next_step.each do |signalled, sources|
			sources.each do |emit, source, context|
			    source.generator.signalling(source, signalled) if source

			    if already_seen.include?(signalled) && !(emit && signalled.pending?) 
				# Do not fire the same event twice in the same propagation cycle
				next unless signalled.propagation_mode == :always_call
			    end

			    did_call = propagation_context(source) do |result|
				if !emit && signalled.controlable?
				    signalled.call_without_propagation(context) 
				else
				    signalled.emit_without_propagation(context)
				end
			    end
			    already_seen << signalled if did_call
			end
		    end
		end
	    end        
	    return self

	ensure
	    Thread.current[:propagation_id] = nil
	end
    end
end


