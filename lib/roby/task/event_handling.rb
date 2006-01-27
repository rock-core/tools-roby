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


module Roby
    class Task
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
        # the handlers defined in the task model by Task::each_handler
        def each_handler(event, &iterator)
            event = model.validate_events(event).first.symbol
            
            model.each_handler(event, &iterator)
            return unless event_handlers.has_key?(event)
            event_handlers[event].each(&iterator)
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

        # call-seq:
        #   each_handler(event) { |event| ... }
        #   
        # Enumerates all event handlers defined for +event+ in the task model
        def self.each_handler(event, &iterator) 
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
end

