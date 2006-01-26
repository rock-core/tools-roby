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

        # If this task is currently running
        def running?;   !history.empty? && history.last[1].symbol != :end end
        # If this task ran and is finished
        def finished?;  !history.empty? && history.last[1].symbol == :end end
            
        # Emits +name+ in the given +context+. Event handlers are fired.
        #
        # call-seq:
        #   emit(name, context)                       event object
        #
        def emit(name, context = nil)
            klass = model.validate_events(name).first 
            if finished?
                raise TaskModelViolation, "emit called but the task has finished"
            elsif !running? && name != :start
                raise TaskModelViolation, "emit called for event #{name}, but the task is not running"
            end

            event = klass.new(self, context)

            # Add the event to our history
            history << [Time.now, event]

            if fired_event(event)
                # Call event handlers
                each_handler(name) { |h| 
                    if before_calling_handler(event, h)
                        h.call(self, event) 
                    end
                    after_calling_handler(event, h)
                }
            end
            
            # Return the event object
            event
        end

        # call-seq:
        #   on(from, task, event1, event2, ...) { |task, event| ... }
        #
        # Adds an event handler for the event +from+. When +from+ is fired,
        # * all provided events will be provoked in +task+. As such, all of these
        #   events shall be controlable
        # * calls the supplied handler when _from_ is triggered in the receiver. The block
        #   is called with the originating task, and the event object
        def on(from, *args, &user_handler)
            from = model.validate_events(from).first
            unless args.size >= 2 || (args.size == 0 && user_handler)
                raise ArgumentError, "Bad call for Task#on. Got #{args.size + 1} arguments and #{block_given? ? 1 : 0} block"
            end

            handlers = []
            if args.size >= 2
                task, *to = *args
                to = task.model.validate_events(*to)
                if to.find { |e| !e.controlable? }
                    raise ArgumentError, "All events shall be controlable"
                end

                handlers << lambda do |from_task, event|
                    to.each { |e| e.call(task, e, event.context) }
                end
            end
            handlers << user_handler if user_handler
                    
            @event_handlers[from.symbol] |= handlers
            handlers.each { |h| added_event_handler(from, h) }
        end
        
        # Iterates on all event handlers defined for +event+. This includes
        # the handlers defined in the task model by Task::each_handler
        def each_handler(event, &iterator)
            event = model.validate_events(event).first.symbol
            
            model.each_handler(event, &iterator)
            
            return unless @event_handlers.has_key?(event)
            @event_handlers[event].each(&iterator)
        end

        # call-seq:
        #   on(from, task, event1, event2, ...) { |task, event| ... }
        #
        # Adds an event handler for the event +from+. When +from+ is fired,
        # * all provided events will be provoked in the current task. These events shall
        #   either be controlable events or aliases of +from+
        # * calls the supplied handler when +from+ is triggered in the receiver. The block
        #   is called with the originating task and the event object
        def self.on(from, *args, &user_handler)
            from = validate_events(from).first

            if user_handler
                @event_handlers[from.symbol] << user_handler
            end

            if !args.empty?
                args = validate_events(*args)
                @event_handlers[from.symbol] << lambda do |from_task, event|
                    args.each { |ev| ev.call(from_task, e, event.context) }
                end
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

