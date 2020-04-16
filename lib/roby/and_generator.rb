# frozen_string_literal: true

module Roby
    # Combine event generators using an AND. The generator will emit once all
    # its source events have emitted, and become unreachable if any of its
    # source events have become unreachable.
    #
    # For instance,
    #
    #    a = task1.start_event
    #    b = task2.start_event
    #    (a & b) # will emit when both tasks have started
    #
    # And events will emit only once, unless #reset is called:
    #
    #    a = task1.intermediate_event
    #    b = task2.intermediate_event
    #    and_ev = (a & b)
    #
    #    a.intermediate_event!
    #    b.intermediate_event! # and_ev emits here
    #    a.intermediate_event!
    #    b.intermediate_event! # and_ev does *not* emit
    #
    #    and_ev.reset
    #    a.intermediate_event!
    #    b.intermediate_event! # and_ev emits here
    #
    # The AndGenerator tracks its sources via the signalling relations, so
    #
    #    and_ev << c.intermediate_event
    #
    # is equivalent to
    #
    #    c.intermediate_event.add_signal and_ev
    #
    class AndGenerator < EventGenerator
        def initialize
            super do |context|
                emit_if_achieved(context)
            end

            # This hash is a event_generator => event mapping of the last
            # events of each event generator. We compare the event stored in
            # this hash with the last events of each source to know if the
            # source fired since it has been added to this AndGenerator
            @events = {}

            # This flag is true unless we are not waiting for the emission
            # anymore.
            @active = true
        end

        # After this call, the AndGenerator will emit as soon as all its source
        # events have been emitted again.
        #
        # Example:
        #    a = task1.intermediate_event
        #    b = task2.intermediate_event
        #    and_ev = (a & b)
        #
        #    a.intermediate_event!
        #    b.intermediate_event! # and_ev emits here
        #    a.intermediate_event!
        #    b.intermediate_event! # and_ev does *not* emit
        #
        #    and_ev.reset
        #    a.intermediate_event!
        #    b.intermediate_event! # and_ev emits here
        def reset
            @active = true
            each_parent_object(EventStructure::Signal) do |source|
                @events[source] = source.last
                if source.respond_to?(:reset)
                    source.reset
                end
            end
        end

        # Helper method that will emit the event if all the sources are emitted.
        def emit_if_achieved(context) # :nodoc:
            return if @events.empty? || !@active

            each_parent_object(EventStructure::Signal) do |source|
                return if @events[source] == source.last
            end
            @active = false
            emit(nil)
        end

        # True if the generator has no sources
        def empty?
            relation_graph_for(EventStructure::Signal).root?(self)
        end

        # Adds a new source to +events+ when a source event is added
        def added_signal_parent(parent, info) # :nodoc:
            super
            @events[parent] = parent.last

            # If the parent is unreachable, check that it has neither been
            # removed, nor it has been emitted
            parent.if_unreachable(cancel_at_emission: true) do |reason, event|
                if @events.has_key?(parent) && @events[parent] == parent.last
                    @active = false
                    unreachable!(reason || parent)
                end
            end
        end

        # Removes a source from +events+ when the source is removed
        def removed_signal_parent(parent) # :nodoc:
            super
            @events.delete(parent)
            emit_if_achieved(nil)
        end

        # The set of source events
        def events
            each_parent_object(EventStructure::Signal).to_set
        end

        # The set of generators that have not been emitted yet.
        def waiting
            each_parent_object(EventStructure::Signal).find_all { |ev| @events[ev] == ev.last }
        end

        # Add a new source to this generator
        def <<(generator)
            generator.add_signal self
            self
        end
    end
end
