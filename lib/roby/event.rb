# Base class for events
class Event
    # The task which fired this event
    attr_reader :task
    # The event context
    attr_reader :context

    
    def initialize(task, context = nil)
        @task = task
        @context  = context
    end

    # If the event model defines a controlable event
    def self.controlable?; respond_to?(:call) end
    # If the event is controlable
    def controlable?; self.class.controlable? end
    # If the event model defines a terminal event
    def self.terminal?; @terminal end
    # If the event is terminal
    def terminal?; self.class.controlable? end
    # The event symbol
    def self.symbol; @symbol end
    # The event symbol
    def symbol; self.class.symbol end
end

