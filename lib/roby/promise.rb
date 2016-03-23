module Roby
    # An extension to {Concurrent::Promise} that is aware of the mixed thread/event
    # loop nature of Roby
    #
    # Use {ExecutionEngine#promise} to create one
    #
    # {#on_success} and {#rescue} gain an in_engine argument, which decides
    # whether the given block should be executed by the underlying execution
    # engine's or not. It is true by default. Note that {#then} is not overriden
    class Promise
        # The execution engine we execute on
        attr_reader :execution_engine
        # The actual Promise object from concurrent-ruby
        attr_reader :promise

        def initialize(execution_engine, promise)
            @execution_engine = execution_engine
            execution_engine.waiting_work << self
            @promise = promise
        end

        def on_success(in_engine: true)
            if in_engine
                child = promise.on_success do |*args|
                    execution_engine.execute(type: :propagation) do
                        yield(*args)
                    end
                end
            else
                child = promise.on_success(&proc)
            end
            Promise.new(execution_engine, child)
        end

        def then(rescuer = nil, &block)
            child = promise.then(rescuer, &block)
            Promise.new(execution_engine, child)
        end

        def on_error(in_engine: true)
            if in_engine
                child = promise.on_error do |*args|
                    execution_engine.execute(type: :propagation) do
                        yield(*args)
                    end
                end
            else
                child = promise.rescue(&proc)
            end
            Promise.new(execution_engine, child)
        end

        def execute
            promise.execute
        end

        def pending?
            promise.pending?
        end

        def unscheduled?
            promise.unscheduled?
        end

        def complete?
            promise.complete?
        end

        def fulfilled?
            promise.fulfilled?
        end

        def value(timeout = nil)
            promise.value(timeout)
        end

        def value!(timeout = nil)
            promise.value!(timeout)
        end

        def reason
            promise.reason
        end

        def wait(timeout = nil)
            promise.wait(timeout)
        end
    end
end

