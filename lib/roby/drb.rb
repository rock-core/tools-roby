require 'drb'
require 'roby/support'
require 'roby/task'
require 'roby/event'
require 'roby/plan'
require 'roby/control'

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
        def quit
            Control.quit
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

