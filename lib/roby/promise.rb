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
        # The pipeline that will be executed if an error happens in {#pipeline}
        #
        # @return [Array<PipelineElement>]
        attr_reader :error_pipeline

        def initialize(execution_engine, executor: execution_engine.thread_pool, description: "promise", &block)
            @execution_engine = execution_engine
            execution_engine.waiting_work << self
            @description = description

            @pipeline = Array.new
            @error_pipeline = Array.new
            @promise = Concurrent::Promise.new(executor: executor, &method(:run_pipeline))
            @current_element = Concurrent::AtomicReference.new
            if block
                self.then(&block)
            end
        end

        # The description element being currently executed
        #
        # @return [String,nil] 
        def current_element
            @current_element.get
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

            execution_engine.log_timepoint_group "#{description}" do
                begin
                    run_pipeline_elements(self.pipeline, state)
                rescue Exception => exception
                    run_pipeline_elements(self.error_pipeline, exception, propagate_state: false)
                    raise Failure.new(exception)
                end
            end
        ensure
            @current_element.set(nil)
        end

        # @api private
        #
        # Run one of {#pipeline} or {#error_pipeline}
        def run_pipeline_elements(pipeline, state, propagate_state: true)
            pipeline = pipeline.dup
            while !pipeline.empty?
                state = run_one_pipeline_segment(pipeline, state, false, propagate_state: propagate_state)
                if !pipeline.empty?
                    state = execution_engine.log_timepoint_group "#{description}:execute_in_engine" do
                        execution_engine.execute(type: :propagation) do
                            run_one_pipeline_segment(pipeline, state, true, propagate_state: propagate_state)
                        end
                    end
                end
            end
            state
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
        # Helper method for {#run_pipeline_elements}, to run a sequence of
        # elements in a pipeline that have the same run_in_engine? 
        def run_one_pipeline_segment(pipeline, state, in_engine, propagate_state: true)
            while (element = pipeline.first) && !(in_engine ^ element.run_in_engine)
                pipeline.shift
                @current_element.set(element.description)
                new_state = execution_engine.log_timepoint_group "#{element.description} in_engine=#{element.run_in_engine}" do
                    element.callback.call(state)
                end
                state = new_state if propagate_state
            end
            state
        end

        def to_s
            "#<Roby::Promise #{description}>"
        end

        def pretty_print(pp)
            description = self.description
            pp.text "Roby::Promise(#{description}"
            if current_element = self.current_element
                pp.text ", currently: #{current_element})"
            else
                pp.text ")"
            end

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
            error_pipeline.each do |element|
                pp.nest(2) do
                    pp.text "."
                    pp.breakable
                    pp.text "on_error(#{element.description}, in_engine: #{element.run_in_engine})"
                end
            end
        end

        # Whether self already has an error handler
        #
        # Unlike {Concurrent::Promise}, {Roby::Promise} objects can only have
        # one error handler
        def has_error_handler?
            !error_pipeline.empty?
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
            error_pipeline << PipelineElement.new(description, in_engine, block)
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
            self
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

        def wait
            promise.wait
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

        # The promise's execution state
        def state
            promise.state
        end

        # Register a block that will be called on this promise's termination
        #
        # @yieldparam [Time] time the termination time
        # @yieldparam [Object,nil] result the promise result if it finished
        #   execution successfully, or nil if an exception was raised
        # @yieldparam [Object,nil] reason the exception that terminated this
        #   promise if it failed, or nil if it finished successfully
        def add_observer(&block)
            promise.add_observer(&block)
        end
    end
end

