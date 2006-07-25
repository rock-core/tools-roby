require 'drb'
require 'roby/support'
require 'roby/task'
require 'roby/event'
require 'roby/plan'

module Roby
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

