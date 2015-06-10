module Roby
    # Event objects are the objects representing a particular emission in the
    # event propagation process. They represent the common propagation
    # information (time, generator, sources, ...) and provide some common
    # functionalities related to propagation as well.
    class Event
        # The generator which emitted this event
	attr_reader :generator

	def initialize(generator, propagation_id, context, time = Time.now)
	    @generator, @propagation_id, @context, @time = generator, propagation_id, context.freeze, time
            @sources = ValueSet.new
	end

        def plan
            generator.plan
        end

	attr_accessor :propagation_id, :context, :time
	protected :propagation_id=, :context=, :time=

        # The events whose emission directly triggered this event during the
        # propagation. The events in this set are subject to Ruby's own
        # garbage collection, which means that if a source event is garbage
        # collected (i.e. if all references to the associated task/event
        # generator are removed), it will be removed from this set as well.
        def sources
            result = ValueSet.new
            @sources.delete_if do |ref|
                begin 
                    result << ref.get
                    false
                rescue Utilrb::WeakRef::RefError
                    true
                end
            end
            result
        end

        # Recursively computes the source event that led to the emission of
        # +self+
        def all_sources
            result = ValueSet.new
            sources.each do |ev|
                result << ev
                result.merge(ev.all_sources)
            end
            result
        end

        # Call to protect this event's source from Ruby's garbage collection.
        # Call this if you want to store the propagation history for this event
        def protect_sources
            @protected_sources = sources
        end

        # Call to recursively protect this event's sources from Ruby's garbage
        # collection. Call this if you want to store the propagation history for
        # this event
        def protect_all_sources
            @protected_all_sources = all_sources
        end

        # Sets the sources. See #sources
        def sources=(new_sources) # :nodoc:
            @sources = ValueSet.new
            add_sources(new_sources)
        end

        def add_sources(new_sources)
            for new_s in new_sources
                @sources << Utilrb::WeakRef.new(new_s)
            end
        end

        def root_sources
            all = all_sources
            all.find_all do |event|
                all.none? { |ev| ev.generator.child_object?(event.generator, Roby::EventStructure::Forwarding) }
            end
        end

	# To be used in the event generators ::new methods, when we need to reemit
	# an event while changing its 
	def reemit(new_id, new_context = nil)
	    if propagation_id != new_id || (new_context && new_context != context)
		new_event = self.dup
		new_event.propagation_id = new_id
		new_event.context = new_context
		new_event.time = Time.now
		new_event
	    else
		self
	    end
	end

	def name; model.name end
	def model; self.class end
	def inspect # :nodoc:
            "#<#{model.to_s}:0x#{address.to_s(16)} generator=#{generator} model=#{model}"
        end

        # Returns an event generator which will be emitted once +time+ seconds
        # after this event has been emitted.
        def after(time)
            State.at :t => (self.time + time)
        end

	def to_s # :nodoc:
	    "[#{Roby.format_time(time)} @#{propagation_id}] #{self.class.to_s}: #{context}"
	end

        def pretty_print(pp, with_context = true) # :nodoc:
            pp.text "[#{Roby.format_time(time)} @#{propagation_id}] #{self.class}"
            if with_context && context
                pp.breakable
                pp.nest(2) do
                    pp.text "  "
                    pp.seplist(context) do |v|
                        v.pretty_print(pp)
                    end
                end
            end
        end

        def to_execution_exception
            generator.to_execution_exception
        end

        def to_execution_exception_matcher
            generator.to_execution_exception_matcher
        end
    end
end

