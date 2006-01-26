require 'enumerator'
require 'roby/event'
require 'roby/support'

module Roby
    class TaskModelViolation < RuntimeError; end

    class Task
        # The task model
        def model; singleton_class end

        # If a model of +event+ is defined in this task model
        def has_event?(event); model.has_event?(event) end
        
        # call-seq:
        #   self.event(name, options = nil)                   -> event class or nil
        #
        # Define a new event in this task. The event definition can be aborted by the
        # Task#new_event_model callback. This is usually done by raising a 
        # TaskModelViolation exception, but can also be done silently. In that case
        # the method returns nil
        #
        # ==== Available options
        #
        # <tt>:command</tt>::
        #   either an event command for the new event, which is an object which must respond
        #   to proc, +true+ or +false+. If it is true, a default handler is defined which 
        #   simply emits the event. +false+ can be used to override the automatic definition
        #   of the event command (see below).
        #
        # <tt>:terminal</tt>::
        #   set to true if this event is a terminal event
        #
        # <tt>:model</tt>::
        #   base class for the event model (see "Event models" below). The default is the 
        #   Event class
        #
        #
        # ==== Automatic event command
        #
        # If the task class defines a method with the same name as the
        # event, then the event is controlable, and this method is defined
        # as the event command.
        #
        # Setting the <tt>:command</tt> option explicitely to a false value overrides 
        # this behaviour (use +false+ or +nil+ to disable the command handler)
        #
        #
        # ==== Event models
        #
        # The event model is described using a Ruby class. Task::event defines a 
        # class, usually a subclass of Event and stores it in MyTaskClass::MyEvent
        # for a my_event event. Then, when the event is emitted, the event object
        # will be an instance of this particular class. To override the base class
        # for a particular event, use the <tt>:model</tt> option
        #
        def self.event(ev, options = nil)
            options = validate_options(options, :command => nil, :terminal => nil, :model => Event)
            validate_event_definition_request(ev, options)

            ev_s = ev.to_s
            ev = ev.to_sym

            if options[:terminal] && has_event?(:end)
                raise ArgumentError, "trying to define a terminal event, but the end event is already defined"
            end

            # Set self_task to the task class we are defining
            # to use it in the Event class definition
            self_task = self

            if options.has_key?(:command)
                if options[:command].respond_to?(:call)
                    command_handler = options[:command]
                elsif options[:command] == true
                    command_handler = lambda { |task, event, *context| task.emit(event, *context) }
                elsif options[:command]
                    raise ArgumentError, "Allowed values for :command option: true, false, nil and an object responding to #call. Got #{options[:command]}"
                end
            elsif self_task.instance_methods.include?(ev_s)
                command_handler = lambda { |task, *args| task.send(ev, *args) }
            end

            # Define the event class
            new_event = Class.new(options[:model]) do
                @symbol = ev
                @terminal = options[:terminal]

                @command_handler = command_handler
                if @command_handler
                    # Forwarder to provide a default argument for +event+
                    def self.call(task, event = self.symbol, *args) #:nodoc:
                        @command_handler.call(task, event, *args)
                    end
                end
            end

            if new_event_model(new_event)
                const_set(ev_s.camelize, new_event)
                new_event
            end
        end

        # Iterates on all event models defined for this model
        def self.each_event(&iterator) # :yields: event
            constants.each do |const_name|
                const_value = const_get(const_name)
                if const_value.has_ancestor?(Event)
                    yield const_value
                end
            end
        end

        # Get the list of terminal events for this model
        def self.terminal_events; enum_for(:each_event).find_all { |e| e.terminal? } end
        # Find the event class for +event+, or nil if +event+ is not an event name for this model
        def self.find_event(event); 
            enum_for(:each_event).find { |e| e.symbol == event.to_sym } 
        end
          
        def self.validate_event_definition_request(ev, options) #:nodoc:
            if has_event?(ev)
                raise ArgumentError, "event #{ev} already defined"
            elsif ev.to_sym == :begin && options[:terminal]
                raise TaskModelViolation, "the 'begin' event cannot be terminal"
            elsif ev.to_sym == :end && options.has_key?(:terminal) && !options[:terminal]
                raise TaskModelViolation, "the 'end' event cannot be non-terminal"
            end
        end

        # Checks that all events in +events+ are valid events for this task.
        # The requested events can be either an event name (symbol or string)
        # or an event class
        #
        # Returns the corresponding array of event classes
        def self.validate_events(*events) #:nodoc:
            events.map { |e|
                if e.respond_to?(:to_sym)
                    ev_model = find_event(e.to_sym)
                    raise ArgumentError, "#{e} is not an event of #{name}" unless ev_model
                elsif e.has_ancestor?(Event)
                    # Check that e is an event class for us
                    ev_model = find_event(e.symbol)
                    if !ev_model
                        raise ArgumentError, "no #{e.symbol} event in #{name}"
                    elsif ev_model != e
                        raise ArgumentError, "the event model #{e} is not a model for #{name} (found #{ev_model} with the same name)"
                    end
                else 
                    raise ArgumentError, "wanted either a symbol or an event class, got #{e}"
                end

                ev_model
            }
        end

        class << self #:nodoc:
            # Checks if _name_ is a name for an event of this task
            alias :has_event? :find_event

            def event_handlers #:nodoc:
                @event_handlers ||= Hash.new
            end
            
            private :validate_event_definition_request
        end
        
        # Callback called when an event class has been defined, but before it is registered.
        #
        # Returns true if the event should be registered, false otherwise. The preferred
        # way to abort an event definition is to raise a TaskModelViolation exception.
        # 
        def self.new_event_model(klass)
            if superclass.respond_to?(:new_event_model)
                superclass.new_event_model(klass)
            else
                true
            end
        end
    end
end
        

