require 'drb'
require 'roby/support'
require 'roby/task'
require 'roby/event'
require 'roby/plan'

module Roby
    # Mark core classes to be undumpable
    class Task
        include DRbUndumped
    end
    class Event
        include DRbUndumped
    end
    class Plan
        include DRbUndumped
    end

   
    # The DRb server
    class Server
        def initialize(event_loop)
            @event_loop = event_loop
        end
        def insert(task_model_name)
            task_model_name = task_model_name.classify
            new_task = Roby.const_get(task_kind).new
            
            yield(new_t.ask) if block_given?
            @event_loop.sent_to(@plan, insert, new_task)
            
        end
        def call(task, event, context)
            event_model = task.event_model(event)
            @event_loop.send_to(event_model, :call, task, context)
        end
        def quit
            @event_loop.raise Interrupt
        end
    end

    # The DRb client
    class Client < DRbObject
        def initialize(uri)
            super(nil, uri)
        end
        def quit
            super
        rescue DRb::DRbConnError
        end
    end
end

