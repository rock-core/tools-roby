require 'roby/event'
require 'roby/support'

module Roby
    class TaskModelViolation < RuntimeError; end

    class Task
        # Builds a task object using this task model
        # The task object can be configured by a given block. After the 
        # block is called, two things are checked:
        # * the task shall have a +start+ event
        # * the task shall have at least one terminal event. If no +stop+ event
        #   is defined, then all terminal events are aliased to +stop+
        def initialize #:yields: task_object
            @history = Array.new
            @signalling = Hash.new { |h, k| h[k] = Array.new }

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

        attr_reader :signalling # :nodoc:
        attr_reader :event_handlers # :nodoc:

        # If this task is currently running
        def running?;   !history.empty? && history.last[1].symbol != :stop end
        # If this task ran and is finished
        def finished?;  !history.empty? && history.last[1].symbol == :stop end
            
        # Do event propagation. Return an array of [event, [handlers]] pair
        # of the fired being fired in the propagation and the handlers 
        # that should be called
        #
        # Task#propagate handles event signalling, that is the event propagation
        # set by Task#on(from, task, to)
        PropagationResult = Struct.new(:commands, :handlers)
        class PropagationResult
            def |(other)
                PropagationResult.new self.commands | other.commands, self.handlers | other.handlers
            end
        end

        def propagate(event_model, context)
            event_model = model.validate_events(event_model).first 
 
            if event_model.command_handler
                result = PropagationResult.new [], []
                result.commands = [[ self, context, event_model ]]
                return result
            else
                return fire_event(event_model, context)
            end
        end
        
        def fire_event(event_model, context)
            if finished? && event_model.symbol != :stop
                raise TaskModelViolation, "emit(#{event_model.symbol}: #{event_model}) called but the task has finished"
            elsif !running? && !finished? && event_model.symbol != :start
                raise TaskModelViolation, "emit(#{event_model.symbol}: #{event_model}) called but the task is not running"
            end

            # Fire the event ourselves
            event = event_model.new(self, context)
            history << [Time.now, event]

            result = PropagationResult.new [], []
            result.handlers << [ event, enum_for(:each_handler, event.symbol).to_a ]

            each_signal(event_model.symbol) do |task, event|
                result |= (task || self).propagate(event, context)
            end

            result |= super if defined? super
            return result
        end
        
        # Emits +name+ in the given +context+. Event handlers are fired.
        # This is not meant to fire commandable events. Use #send_command for that
        #
        # call-seq:
        #   emit(name, context)                       event object
        #
        def emit(event_model, context = nil)
            event_model = model.validate_events(event_model).first 

            result = fire_event(event_model, context)

            # Call event handlers
            result.handlers.each do |event, event_handlers|
                task = event.task
                event_handlers.each do |handler|
                    if task.before_calling_handler(event, handler)
                        handler.call(event) 
                    end
                    task.after_calling_handler(event, handler)
                end
            end

            # Call event commands
            result.commands.each do |task, context, event_model|
                event_model.call(task, context)
            end

            self
        end

        # Returns an BoundEvent object which represents the given event bound
        # to this particular task
        def event(event_model)
            event_model = model.validate_events(event_model).first
            BoundEvent.new(self, event_model)
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

                signalling[event_model.symbol] += to_events.map { |ev| [to_task, ev] }
            end
            if user_handler
                check_arity(user_handler, 1)
                handlers << user_handler
            end
                    
            event_handlers[event_model.symbol] += handlers
            handlers.each { |h| added_event_handler(event_model, h) }
        end

        # Calls the command for +event+ on this task, in the given context
        def send_command(event_model, context = nil)
            event_model = model.validate_events(event_model).first
            event_model.call(self, context)
        end
        
        # :section: Callbacks
        
        # Callback called when an event handler is added for +event+
        # *Return* false to discard the handler
        def added_event_handler(event, handler); true end

        # Callback called in Task#emit just before calling the event handler +h+
        # because we are emitting +e+
        # *Return* true if the handler is to be called, false otherwise
        def before_calling_handler(e, h); true end
        # Callback called in Task#emit just after the event handler +h+ has been called while
        # emitting the event +e+
        def after_calling_handler(e, h); end



        # :section: Event model
        
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
        def self.event(ev, options = nil)
            options = validate_options(options, :command => nil, :terminal => nil, :model => Event)
            validate_event_definition_request(ev, options)

            ev_s = ev.to_s
            ev = ev.to_sym

            if options[:terminal] && has_event?(:stop)
                raise ArgumentError, "trying to define a terminal event, but the stop event is already defined"
            elsif options[:command] && options[:command] != true && !options[:command].respond_to?(:call)
                raise ArgumentError, "Allowed values for :command option: true, false, nil and an object responding to #call. Got #{options[:command]}"
            end

            if !options.has_key?(:command) && instance_methods.include?(ev_s)
                method = instance_method(ev)
                check_arity(method, 1)
                options[:command] = lambda { |t, c| method.bind(t).call(c) }
            end

            command_handler = options[:command] if options[:command].respond_to?(:call)
            
            # Define the event class
            new_event = Class.new(options[:model]) do
                @symbol   = ev
                @terminal = options[:terminal]
                @command_handler = command_handler

                class << self
                    attr_reader :command_handler
                end
            end

            if options[:command]
                if options[:command].respond_to?(:call)
                    check_arity(options[:command], 2)
                    def new_event.call(task, context)
                        command_handler.call(task, context)
                    end
                else
                    def new_event.call(task, context)
                        task.emit symbol, context
                    end
                end
                
                # Define a bang method on self which calls the command
                define_method ev_s + '!', 
                    &lambda { |*context| 
                        context = *context
                        new_event.call(self, context) 
                    }
            end

            if new_event_model(new_event)
                const_set(ev_s.camelize, new_event)
                new_event
            end
        end

        def each_event(&iterator); self.class.each_event(&iterator) end
        # Iterates on all event models defined for this task model
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
        def self.event_model(event)
            validate_event_models(event).first
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
                    unless ev_model
                        all_events = enum_for(:each_event).
                            to_a.
                            map { |ev| ev.symbol }
                        raise ArgumentError, "#{e} is not an event of #{name} #{all_events.inspect}" unless ev_model
                    end
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

        def self.signalling
            @signalling ||= Hash.new { |h, k| h[k] = Array.new }
        end
        def self.event_handlers #:nodoc:
            @event_handlers ||= Hash.new { |h, k| h[k] = Array.new }
        end
        
        class << self
            # Checks if _name_ is a name for an event of this task
            alias :has_event? :find_event

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

        # Iterates on all event handlers defined for +event+. This includes
        # the handlers defined in the task models, by calling model.each_handler
        # See TaskModel::each_handler
        def each_handler(event, &iterator)
            event_handlers[event].each(&iterator)
            model.each_handler(event, &iterator)
        end

        # call-seq:
        #   each_handler(event) { |event| ... }
        #   
        # Enumerates all event handlers defined for +event+ in the task model
        def self.each_handler(event, &iterator) 
            superclass.each_handler(event, &iterator) if superclass.respond_to?(:each_handler)
            event_handlers[event].each(&iterator)
        end

        def each_signal(event, &iterator)
            signalling[event].each(&iterator)
            model.each_signal(event, &iterator)
        end

        # call-seq:
        #   each_signal(event) { |task, event| ... }
        # Enumerates all event signals that comes from +event+
        def self.each_signal(event, &iterator)
            superclass.each_signal(event, &iterator) if superclass.respond_to?(:each_signal)
            signalling[event].each(&iterator)
        end

        # call-seq:
        #   on(event_model) { |event| ... }
        #   on(event_model => ev1, ev2 => [ ev3, ev4 ]) { |event| ... }
        #
        # Adds an event handler for the given event model. When the event is fired,
        # all events given in argument will be called. If they are controlable,
        # then the command is called. If not, they are just fired
        def self.on(mappings, &user_handler)
            source_events = []
            mappings = [*mappings].zip([]) unless Hash === mappings

            mappings.each do |from, to|
                from = validate_events(from).first
                source_events << from
                next unless to && ![*to].empty?
                to   = validate_events(*to)

                signalling[from.symbol] += to.map { |event| [nil, event] }
            end
                    
            if user_handler
                source_events.each { |model| event_handlers[model.symbol] << user_handler }
            end
        end
    end
end

require 'roby/relations'
require 'roby/relations/hierarchy'
require 'roby/task-operations'

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

