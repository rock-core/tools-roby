module Roby
    module Tasks

    # This task represents a separate thread in the plan. At definition, the
    # thread's implementation is defined using the +implementation+ statement:
    #
    #   class MyThread < ThreadTask
    #     implementation do
    #       do_some_stuff
    #     end
    #   end
    #
    # The task will emit +failed+ if the given block raises an exception,
    # and emit +success+ otherwise. In that latter case, the returned value
    # is saved in the +result+ attribute.
    #
    # By default, the task is not interruptible (i.e. +stop+ is not
    # controllable). The +interruptible+ statement allows to change that, in
    # which case, the thread must either check for
    # {#interruption_requested?}, or call #interruption_point explicitely,
    # when the interruption can be safely performed by raising an exception. 
    class Thread < Roby::Task
        # The thread result if the execution was successful
        attr_reader :result

        class << self
            # The implementation block for that task model
            attr_reader :implementation_block

	    # Defines the block which should be executed in the separate
	    # thread. The currently defined block can be accessed
	    # through the implementation_block attribute.
            def implementation(&block)
                @implementation_block = block
            end
        end

        # True if Roby requests that the thread quits
        def interruption_requested?
            @interruption_event.set?
        end

        def initialize(arguments = Hash.new, one_shot: true)
            @one_shot = one_shot
            super(arguments)
        end

        # True if the thread will quit by itself, or run until an interruption
        # is requested
        #
        # In the one shot case, a thread quitting without the stop event pending
        # is considered a success. In the latter case, a failure
        #
        # The default is one shot
        attr_predicate :one_shot?, true

        # Call that method in the interruption thread at points where an
        # interruption is safe. It will raise Interrupt if an interruption has
        # been requested through the task's events.
        def interruption_point
            if interruption_requested?
                raise Interrupt, "interruption requested"
            end
        end

        # @api private
        #
        # Start the underlying thread and the monitoring objects
        def start_thread
            @interruption_event = Concurrent::Event.new
            @thread = ::Thread.new do
		::Thread.current.priority = 0
                instance_eval(&self.class.implementation_block)
            end
        end

        event :start do |context|
            start_thread
            start_event.emit
        end

	poll do
	    if @thread.alive?
		return 
	    end

            begin
                result = @thread.value
            rescue Exception => e
                error = e
            end
            @thread = nil

            if error || (!one_shot? && !stop_event.pending?)
                failed_event.emit(error || result)
            else
                @result = result
                success_event.emit(result)
            end
        end

        # Call this method in the model definition to declare that the thread
        # implementation will call #interruption_point regularly.
        def self.interruptible
            event :failed, terminal: true do |context|
                @interruption_event.set
            end
            super
        end
    end
    end
end

