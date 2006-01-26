require 'roby/event'
require 'roby/support'

module Roby
    # Base class for event aliases
    class EventAlias < Event
        class << self
            # The list of events aliased by this one
            attr_accessor :aliased_events

            # Iterate on all events of which this event is an alias
            def each_aliased_events(&p)
                aliased_events.each(&p) if aliased_events
            end
        end
    end

    # Task support for event aliases
    #
    # This module defines the support for event aliases using the callbacks
    # in Task. It is mixed in Task
    #
    # It creates the link between the base events and their aliases
    # For controllable aliases, the link alias -> event should be done 
    # by the event model itself
    #
    module EventAliasHandling
        def initialize #:nodoc:
            # Add the needed event handlers for the events already defined
            # in the task class
            model.each_event do |e|
                EventAliasHandling.define_alias_handler(self, e)
            end

            super
        end

        # Add alias handlers in +task+ for events aliased by +alias_model+
        # +task+ can be either a task object or a task model
        def self.define_alias_handler(task, alias_model) #:nodoc:
            return unless alias_model.respond_to?(:each_aliased_events)

            alias_model.each_aliased_events do |aliased|
                task.on(aliased) do |from_task, event| 
                    # Either from_task == task or from_task.model == task
                    from_task.emit(alias_model, event.context)
                end
            end
        end

        module ClassExtension
            # Add event handler for events aliased by +event+
            def new_event_model(event) #:nodoc:
                EventAliasHandling.define_alias_handler(self, event)
                superclass.new_event_model(event) if superclass.respond_to?(:new_event_model)
            end
        
            # Defines an event alias
            #
            # An event aliases a group G of events if the following constraints are met:
            # * the alias is fired if any event of G is fired
            # * if the alias is controlable, then its command shall emit
            #   at least one of the events in G
            #
            # A consequence of these two rules is that if the alias is terminal, then 
            # all events in G shall be terminal
            # 
            # ==== Valid options
            # +command+:: the command for this event, if the alias should be controlable
            # +model+::   the event class to use as a base class for this alias. This class shall define
            #             +each_aliased_events+ which iterates on all events this event model aliases. 
            #             Uses EventAlias by default
            #
            def alias_event(new_name, events, options = nil)
                options = validate_options(options, [:command])
                events  = validate_events(*events)

                # Check consistency between options[:terminal] and the events in the event set
                if events.all? { |e| e.terminal? }
                    options[:terminal] = true
                elsif options[:terminal]
                    raise ArgumentError, "aliased events must be either all terminal or all non-terminal"
                end

                options[:model] ||= EventAlias
                new_event = event(new_name, options)
                new_event.aliased_events = events.dup
                new_event
            end
        end
    end

    # Add alias support in Task
    class Task
        # Disabled for now, I don't know if all this alias thing is useful at all
        # include EventAliasHandling
    end
end


