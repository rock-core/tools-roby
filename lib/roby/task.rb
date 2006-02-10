require 'roby/event'
require 'roby/support'

module Roby
    class TaskModelViolation < RuntimeError; end

    class Task
        # Builds a task object using this task model
        # The task object can be configured by a given block. After the 
        # block is called, two things are checked:
        # * the task shall have a +start+ event
        # * the task shall have at least one terminal event. If no +end+ event
        #   is defined, then all terminal events are aliased to +end+
        def initialize #:yields: task_object
            @history = []
            @event_handlers = Hash.new { |h, k| h[k] = Array.new }
            yield self if block_given?

            raise TaskModelViolation, "no start event defined" unless has_event?(:start)

            # Check that this task has at least one terminal event defined
            if model.terminal_events.empty?
                raise TaskModelViolation, "no terminal event for this task"
            elsif !model.has_event?(:stop)
                # Create the stop event for this task, if it is not defined
                stop_ev = model.event(:stop, :terminal => true)
                model.terminal_events.each do |ev|
                    model.on(ev => stop_ev) if ev != stop_ev
                end
            end

            super
        end

        # The task model
        def model; self.class end

        # If a model of +event+ is defined in the task model
        def has_event?(event); model.has_event?(event) end
        
        # The event history. The first event should always be +start+, the last
        # always +end+. It is an array of [ date, event object ] pairs
        #   [
        #       [ begin_date, begin_event ],
        #       [ ..  ]
        #       [ end_date, end_event ]
        #   ]
        attr_reader :history

        attr_reader :event_handlers # :nodoc:

        # If this task is currently running
        def running?;   !history.empty? && history.last[1].symbol != :stop end
        # If this task ran and is finished
        def finished?;  !history.empty? && history.last[1].symbol == :stop end
            
        # Emits +name+ in the given +context+. Event handlers are fired.
        # This is not meant to fire commandable events. Use #send_command for that
        #
        # call-seq:
        #   emit(name, context)                       event object
        #
        def emit(event_model, context = nil)
            event_model = model.validate_events(event_model).first 
            if finished?
                raise TaskModelViolation, "emit(#{event_model}) called but the task has finished"
            elsif !running? && event_model.symbol != :start
                raise TaskModelViolation, "emit(#{event_model}) called but the task is not running"
            end

            event = event_model.new(self, context)

            # Add the event to our history
            history << [Time.now, event]

            if fired_event(event)
                # Call event handlers
                each_handler(event_model.symbol) { |h| 
                    if before_calling_handler(event, h)
                        h.call(event) 
                    end
                    after_calling_handler(event, h)
                }
            end
            
            # Return the event object
            event
        end

        # call-seq:
        #   on(event_model[, task, event1, event2, ...]) { |event| ... }
        #
        # Adds an event handler for the given event model. When an event of this
        # model is fired by this task
        # * all provided events will be provoked in +task+. As such, all of these
        #   events shall be controlable
        # * the supplied handler will be called with the event object
        # 
        # This method calls the added_event_handler callback
        def on(event_model, *args, &user_handler)
            event_model = model.validate_events(event_model).first
            unless args.size >= 2 || (args.size == 0 && user_handler)
                raise ArgumentError, "Bad call for Task#on. Got #{args.size + 1} arguments and #{block_given? ? 1 : 0} block"
            end

            handlers = []
            if args.size >= 2
                to_task, *to_events = *args
                to_events = to_task.model.validate_events(*to_events)
                if to_task != self && not_controlable = to_events.find { |e| !e.controlable? }
                    raise ArgumentError, "all target events shall be controlable, #{not_controlable} is not"
                end

                handlers << lambda do |event|
                    to_events.each { |e| 
                        if e.controlable?
                            e.call(to_task, event.context) 
                        else
                            self.emit(e, event.context)
                        end
                    }
                end
            end
            handlers << user_handler if user_handler
                    
            @event_handlers[event_model.symbol] += handlers
            handlers.each { |h| added_event_handler(event_model, h) }
        end

        # Calls the command for +event+ on this task, in the given context
        def send_command(event_model, context = nil)
            event_model = model.validate_events(event_model).first
            event_model.call(self, context)
        end
        
        # Iterates on all event handlers defined for +event+. This includes
        # the handlers defined in the task models, by calling model.each_handler
        # See TaskModel::each_handler
        def each_handler(event, &iterator)
            event = model.validate_events(event).first.symbol
            
            model.each_handler(event, &iterator)
            return unless event_handlers.has_key?(event)
            event_handlers[event].each(&iterator)
        end

        # Callback called when an event handler is added for +event+
        # *Return* false to discard the handler
        def added_event_handler(event, handler); true end
        # Callback called in Task#emit when an event has been fired, before the event
        # handlers are called
        # *Return* true if the handlers are to be called, false otherwise
        def fired_event(e); true end
        # Callback called in Task#emit just before calling the event handler +h+
        # because we are emitting +e+
        # *Return* true if the handler is to be called, false otherwise
        def before_calling_handler(e, h); true end
        # Callback called in Task#emit just after the event handler +h+ has been called while
        # emitting the event +e+
        def after_calling_handler(e, h); end

    end



    # Module which defines the task models methods and attributes
    module TaskModel
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
        # class, usually a subclass of Event and stores it in MyTask::MyEvent
        # for a my_event event. Then, when the event is emitted, the event object
        # will be an instance of this particular class. To override the base class
        # for a particular event, use the <tt>:model</tt> option
        #
        def event(ev, options = nil)
            options = validate_options(options, :command => nil, :terminal => nil, :model => Event)
            validate_event_definition_request(ev, options)

            ev_s = ev.to_s
            ev = ev.to_sym

            if options[:terminal] && has_event?(:stop)
                raise ArgumentError, "trying to define a terminal event, but the stop event is already defined"
            end

            # Set self_task to the task class we are defining
            # to use it in the Event class definition

            if options.has_key?(:command)
                if options[:command].respond_to?(:call)
                    command_handler = options[:command]
                elsif options[:command] == true
                    command_handler = lambda { |task, context| task.emit(ev, context) }
                elsif options[:command]
                    raise ArgumentError, "Allowed values for :command option: true, false, nil and an object responding to #call. Got #{options[:command]}"
                end
            elsif instance_methods.include?(ev_s)
                command_handler = lambda { |task, context| task.send(ev, context) }
            end

            # Define the event class
            new_event = Class.new(options[:model]) do
                @symbol   = ev
                @terminal = options[:terminal]

                class << self
                    attr_accessor :command_handler
                end
            end

            if command_handler
                new_event.singleton_class.send(:define_method, :call) do |task, *context|
                    context = *context
                    command_handler.call(task, context)
                end
                
                # Define a bang method on self which calls the command
                define_method(ev_s + '!') do |*context|
                    context = *context
                    new_event.call(self, context) 
                end
            end

            if new_event_model(new_event)
                const_set(ev_s.camelize, new_event)
                new_event
            end
        end

        # Iterates on all event models defined for this task model
        def each_event(&iterator) # :yields: event
            constants.each do |const_name|
                const_value = const_get(const_name)
                if const_value.has_ancestor?(Event)
                    yield const_value
                end
            end
        end

        # Get the list of terminal events for this model
        def terminal_events; enum_for(:each_event).find_all { |e| e.terminal? } end
        # Find the event class for +event+, or nil if +event+ is not an event name for this model
        def find_event(event); 
            enum_for(:each_event).find { |e| e.symbol == event.to_sym } 
        end
          
        def validate_event_definition_request(ev, options) #:nodoc:
            if has_event?(ev)
                raise ArgumentError, "event #{ev} already defined"
            elsif ev.to_sym == :start && options[:terminal]
                raise TaskModelViolation, "the 'start' event cannot be terminal"
            elsif ev.to_sym == :stop
                if options.has_key?(:terminal) && !options[:terminal]
                    raise TaskModelViolation, "the 'stop' event cannot be non-terminal"
                else 
                    options[:terminal] = true
                end
            end
        end

        # Get the event model for +event+. +event+ must follow the rules for validate_event_models
        def event_model(event)
            validate_event_models(event).first
        end

        # Checks that all events in +events+ are valid events for this task.
        # The requested events can be either an event name (symbol or string)
        # or an event class
        #
        # Returns the corresponding array of event classes
        def validate_events(*events) #:nodoc:
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

        # Checks if _name_ is a name for an event of this task
        alias :has_event? :find_event

        def event_handlers #:nodoc:
            @event_handlers ||= Hash.new { |h, k| h[k] = Array.new }
        end
        
        private :validate_event_definition_request
    
        # Callback called when an event class has been defined, but before it is registered.
        #
        # Returns true if the event should be registered, false otherwise. The preferred
        # way to abort an event definition is to raise a TaskModelViolation exception.
        # 
        def new_event_model(klass)
            if superclass.respond_to?(:new_event_model)
                superclass.new_event_model(klass)
            else
                true
            end
        end

        # call-seq:
        #   each_handler(event) { |event| ... }
        #   
        # Enumerates all event handlers defined for +event+ in the task model
        def each_handler(event, &iterator) 
            if superclass.respond_to?(:each_handler)
                superclass.each_handler(event, &iterator)
            end
            if event_handlers.has_key?(event)
                event_handlers[event].each(&iterator)
            end
        end

        # call-seq:
        #   on(event_model) { |event| ... }
        #   on(event_model => ev1, ev2 => [ ev3, ev4 ]) { |event| ... }
        #
        # Adds an event handler for the given event model. When the event is fired,
        # all events given in argument will be called. If they are controlable,
        # then the command is called. If not, they are just fired
        def on(mappings, &user_handler)
            source_events = []
            if Hash === mappings
                mappings.each do |from, to|
                    from = validate_events(from).first
                    source_events << from
                    to   = validate_events(*to)

                    event_handlers[from.symbol] << lambda do |src_event|
                        to.each { |to_model| 
                            if to_model.respond_to?(:call)
                                to_model.call(src_event.task, src_event.context) 
                            else
                                src_event.task.emit(to_model, src_event.context)
                            end
                        }
                    end
                end
            else
                source_events += validate_events(mappings)
            end
                    
            if user_handler
                source_events.each { |model| event_handlers[model.symbol] << user_handler }
            end
        end

    end

    class << Task
        include TaskModel
    end
end

# Notes on event handlers, event commands and event models
#
#   * when an event if fired, it is done in a certain context, which
#     is the part of the state of the world which is relevant for this
#     event propagation.
#   * a fired event takes the form of an event object, which is an instance
#     of the event model (i.e. the event class defined by Task::event).
#     emit() creates this event object
#   * *all* event handlers are called with only one argument: this event object
#   * controlable events define a *singleton* method +call(task, context)+ whose
#     purpose is to lead to the emission of the given event on the given task
#     The context is event-specific

