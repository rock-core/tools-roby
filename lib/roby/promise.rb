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
        # Exception raised when attempting to add a child to a promise that
        # already has one
        class AlreadyHasChild < RuntimeError; end

        # Exception raised when attempting to add a child to a final promise
        class Final < RuntimeError; end

        # The execution engine we execute on
        attr_reader :execution_engine
        # The actual Promise object from concurrent-ruby
        attr_reader :promise
        # A description text for debugging purposes
        attr_reader :description
        # This promise's parent
        attr_reader :parent

        def initialize(execution_engine, promise, description: nil, final: false, parent: nil)
            @execution_engine = execution_engine
            execution_engine.waiting_work << self
            @promise = promise
            @description = description

            @final = final
            @parent     = parent
            @on_success = nil
            @on_error   = nil
        end

        def to_s
            "#<Roby::Promise #{description}>"
        end

        # Whether this promise can have children
        #
        # Error handlers (created with {#on_error}) are final by default
        def final?
            @final
        end

        # Whether self already has a success handler
        #
        # Unlike {Concurrent::Promise}, {Roby::Promise} only allows to build
        # pipelines, i.e. a promise can have only one success handler
        def has_success_handler?
            !!@on_success
        end

        # Whether self already has an error handler
        #
        # Unlike {Concurrent::Promise}, {Roby::Promise} objects can only have
        # one error handler
        def has_error_handler?
            !!@on_error
        end

        # True if self or one of its downstream promises have an error handler
        def would_handle_rejections?
            @on_error ||
                (@on_success && @on_success.would_handle_rejections?)
        end

        # Whether this promise's {#reason} has been handled by an error handler
        def has_rejection_handled?
            if would_handle_rejections?
                return true
            end

            p = @parent
            r = reason
            while p
                if p.rejected? && p.reason == r && p.has_error_handler?
                    return true
                end
                p = p.parent
            end
            false
        end

        # Schedule execution of a block on the success of self
        #
        # @param [String] description a textual description useful for debugging
        # @param [Boolean] in_engine whether the block should be executed within
        #   the underlying {ExecutionEngine}, a.k.a. in the main thread, or
        #   scheduled in a separate thread.
        def on_success(description: nil, in_engine: true)
            if final?
                raise Final, "#{self} is final, cannot chain it"
            elsif has_success_handler?
                raise AlreadyHasChild, "#{self} already has a success handler, Roby::Promise can only be used to build pipelines"
            end

            if in_engine
                child = promise.on_success do |*args|
                    execution_engine.execute(type: :propagation) do
                        yield(*args)
                    end
                end
            else
                child = promise.on_success(&proc)
            end
            @on_success = Promise.new(execution_engine, child, parent: self,
                                      description: "#{self.description}.on_success(#{description})")
        end

        # Schedule execution of a block if self or one of its parents failed
        #
        # @param [String] description a textual description useful for debugging
        # @param [Boolean] in_engine whether the block should be executed within
        #   the underlying {ExecutionEngine}, a.k.a. in the main thread, or
        #   scheduled in a separate thread.
        # @yieldparam [Object] reason the exception that caused the failure,
        #   usually an exception that was raised by one of the promise blocks.
        def on_error(description: nil, in_engine: true)
            if final?
                raise Final, "#{self} is final, cannot chain it"
            elsif has_error_handler?
                raise AlreadyHasChild, "#{self} already has an error handler, Roby::Promise supports only one error handler per element in the pipeline"
            end

            if in_engine
                child = promise.on_error do |*args|
                    execution_engine.execute(type: :propagation) do
                        yield(*args)
                    end
                end
            else
                child = promise.rescue(&proc)
            end
            @on_error = Promise.new(execution_engine, child, final: true, parent: self,
                                    description: "#{self.description}.on_error(#{description})")
        end

        # Alias for {#on_success}, but defaulting to execution as a separate
        # thread
        def then(description: nil, &block)
            on_success(description: description, in_engine: false, &block)
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

        def rejected?
            promise.rejected?
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

