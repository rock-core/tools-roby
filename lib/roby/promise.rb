module Roby
    # An extension to {Concurrent::Promise} that is aware of the mixed thread/event
    # loop nature of Roby
    #
    # Use {ExecutionEngine#promise} to create one
    #
    # {#on_success} and {#rescue} gain an in_engine argument, which decides
    # whether the given block should be executed by the underlying execution
    # engine's or not. It is true by default. Note that {#then} is not overriden
    #
    # This promise implementation has no graph capabilities. The execution must
    # be a pipeline, and a whole pipeline is represented by a single Promise.
    # State predicates such as #fulfilled? or #rejected? are valid for the whole
    # pipeline. There is no way to handle errors for only parts of the pipeline.
    class Promise
        class AlreadyHasErrorHandler < RuntimeError; end
        class NotComplete < RuntimeError; end

        # The execution engine we execute on
        attr_reader :execution_engine
        # The Promise object from concurrent-ruby that handles the nominal part
        # of the execution
        attr_reader :promise
        # A description text for debugging purposes
        attr_reader :description
        # The pipeline itself
        #
        # @return [Array<PipelineElement>]
        attr_reader :pipeline

        def initialize(execution_engine, executor: execution_engine.thread_pool, description: nil, &block)
            @execution_engine = execution_engine
            execution_engine.waiting_work << self
            @description = description

            @pipeline = Array.new
            @promise = Concurrent::Promise.new(executor: executor, &method(:run_pipeline))
            if block
                self.then(&block)
            end
        end

        # Representation of one element in the pipeline
        PipelineElement = Struct.new :description, :run_in_engine, :callback

        # @api private
        #
        # Internal implementation of the pipeline. This holds a thread until it
        # is finished - there's no point in giving the thread back between the
        # steps in the pipeline, given how the promises are used in Roby (to
        # avoid freezing due to blocking calls)
        def run_pipeline(*state)
            Thread.current.name = "run_promises"

            pipeline = self.pipeline.dup
            on_error = @on_error
            begin
                while !pipeline.empty?
                    state = run_pipeline_elements(pipeline, state, false)
                    if !pipeline.empty?
                        execution_engine.execute(type: :propagation) do
                            state = run_pipeline_elements(pipeline, state, true)
                        end
                    end
                end
                state
            rescue Exception => exception
                if on_error
                    if on_error.run_in_engine
                        execution_engine.execute(type: :propagation) do
                            on_error.callback.call(exception)
                        end
                    else
                        on_error.callback.call(exception)
                    end
                end
                raise Failure.new(exception)
            end
        end

        # @api private
        #
        # Encapsulation of an exception raised by a callback
        #
        # For whatever reason, the concurrent-ruby developers decided that a
        # non-RuntimeError would be fatal to the promise (not be handled
        # "normally").
        #
        # Roby never had such a constraint, so that's dangerous here.
        # Encapsulate an exception in Failure to pass it out of the
        # concurrent-ruby promise.
        class Failure < RuntimeError
            attr_reader :actual_exception
            def initialize(error)
                @actual_exception = error
            end
        end

        # @api private
        #
        # Helper method for {#run_pipeline}
        def run_pipeline_elements(pipeline, state, in_engine)
            while (element = pipeline.first) && !(in_engine ^ element.run_in_engine)
                pipeline.shift
                state = execution_engine.log_timepoint_group "#{element.description} in_engine=#{element.run_in_engine}" do
                    element.callback.call(state)
                end
            end
            state
        end

        def to_s
            "#<Roby::Promise #{description}>"
        end

        def pretty_print(pp)
            description = self.description
            pp.text "Roby::Promise(#{description})"
            pipeline.each do |element|
                pp.nest(2) do
                    pp.text "."
                    pp.breakable
                    if element.run_in_engine
                        pp.text "on_success(#{element.description})"
                    else
                        pp.text "then(#{element.description})"
                    end
                end
            end
            if @on_error
                pp.nest(2) do
                    pp.text "."
                    pp.breakable
                    pp.text "on_error(#{@on_error.description}, in_engine: #{@on_error.run_in_engine})"
                end
            end
        end

        # Whether self already has an error handler
        #
        # Unlike {Concurrent::Promise}, {Roby::Promise} objects can only have
        # one error handler
        def has_error_handler?
            !!@on_error
        end

        # Schedule execution of a block on the success of self
        #
        # @param [String] description a textual description useful for debugging
        # @param [Boolean] in_engine whether the block should be executed within
        #   the underlying {ExecutionEngine}, a.k.a. in the main thread, or
        #   scheduled in a separate thread.
        def on_success(description: "#{self.description}.on_success[#{pipeline.size}]", in_engine: true, &block)
            pipeline << PipelineElement.new(description, in_engine, block)
            self
        end

        # Schedule execution of a block if self or one of its parents failed
        #
        # @param [String] description a textual description useful for debugging
        # @param [Boolean] in_engine whether the block should be executed within
        #   the underlying {ExecutionEngine}, a.k.a. in the main thread, or
        #   scheduled in a separate thread.
        # @yieldparam [Object] reason the exception that caused the failure,
        #   usually an exception that was raised by one of the promise blocks.
        def on_error(description: "#{self.description}.on_error", in_engine: true, &block)
            if has_error_handler?
                raise AlreadyHasErrorHandler, "Roby::Promise can have only one error handler"
            end
            @on_error = PipelineElement.new(description, in_engine, block)
            self
        end

        # Alias for {#on_success}, but defaulting to execution as a separate
        # thread
        def then(description: "#{self.description}.then[#{pipeline.size}]", &block)
            on_success(description: description, in_engine: false, &block)
        end

        def fail(exception = StandardError)
            promise.fail(exception)
        end

        def execute
            promise.execute
        end

        def unscheduled?
            promise.unscheduled?
        end

        def pending?
            promise.pending?
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
            if promise.complete?
                promise.value(timeout)
            else
                raise NotComplete, "cannot call #value on a non-complete promise"
            end
        end

        def value!(timeout = nil)
            if promise.complete?
                promise.value!(timeout)
            else
                raise NotComplete, "cannot call #value on a non-complete promise"
            end
        rescue Failure => e
            raise e.actual_exception
        end

        # Returns the exception that caused the promise to be rejected
        def reason
            if failure = promise.reason
                failure.actual_exception
            end
        end
    end
end

