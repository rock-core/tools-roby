# frozen_string_literal: true

module Roby
    # Fires when the first of its source events fires.
    #
    # For instance,
    #
    #    a = task1.start_event
    #    b = task2.start_event
    #    (a | b) # will emit as soon as one of task1 and task2 are started
    #
    # Or events will emit only once, unless #reset is called:
    #
    #    a = task1.intermediate_event
    #    b = task2.intermediate_event
    #    or_ev = (a | b)
    #
    #    a.intermediate_event! # or_ev emits here
    #    b.intermediate_event! # or_ev does *not* emit
    #    a.intermediate_event! # or_ev does *not* emit
    #    b.intermediate_event! # or_ev does *not* emit
    #
    #    or_ev.reset
    #    b.intermediate_event! # or_ev emits here
    #    a.intermediate_event! # or_ev does *not* emit
    #    b.intermediate_event! # or_ev does *not* emit
    #
    # The OrGenerator tracks its sources via the signalling relations, so
    #
    #    or_ev << c.intermediate_event
    #
    # is equivalent to
    #
    #    c.intermediate_event.add_signal or_ev
    #
    class OrGenerator < EventGenerator
        # Creates a new OrGenerator without any sources.
        def initialize
            super do |context|
                emit_if_first(context)
            end
            @active = true
        end

        # True if there is no source events
        def empty?
            parent_objects(EventStructure::Signal).empty?
        end

        # Or generators will emit only once, unless this method is called. See
        # the documentation of OrGenerator for an example.
        def reset
            @active = true
            each_parent_object(EventStructure::Signal) do |source|
                if source.respond_to?(:reset)
                    source.reset
                end
            end
        end

        # Helper method called to emit the event when it is required
        def emit_if_first(context) # :nodoc:
            return unless @active

            @active = false
            emit(context)
        end

        # Tracks the event's parents in the signalling relation
        def added_signal_parent(parent, info) # :nodoc:
            super
            parent.if_unreachable(cancel_at_emission: true) do |reason, event|
                if !emitted? && each_parent_object(EventStructure::Signal).all?(&:unreachable?)
                    unreachable!(reason || parent)
                end
            end
        end

        def removed_signal_parent(parent)
            super
            if !emitted? && each_parent_object(EventStructure::Signal).all?(&:unreachable?)
                unreachable!
            end
        end

        # Adds +generator+ to the sources of this event
        def <<(generator)
            generator.add_signal self
            self
        end
    end
end
