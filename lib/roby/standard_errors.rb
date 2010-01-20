module Roby
    # This kind of errors are generated during the plan execution, allowing to
    # blame a fault on a plan object (#failure_point). The precise failure
    # point is categorized in the #failed_event, #failed_generator and
    # #failed_task. It is guaranteed that one of #failed_generator and
    # #failed_task is non-nil.
    class LocalizedError < RuntimeError
        # The object describing the point of failure
	attr_reader :failure_point
        
        # The objects of the given categories which are related to #failure_point
        attr_reader :failed_event, :failed_generator, :failed_task

        # Create a LocalizedError object with the given failure point
        def initialize(failure_point)
	    @failure_point = failure_point
	    if failure_point.kind_of?(Event)
		@failed_event = failure_point
		@failed_generator = failure_point.generator
	    elsif failure_point.kind_of?(EventGenerator)
		@failed_generator = failure_point
	    elsif failure_point.kind_of?(Task)
		@failed_task = failure_point
	    end

	    if !@failed_task && @failed_generator && @failed_generator.respond_to?(:task)
		@failed_task = failed_generator.task
	    end
	    if !@failed_task && !@failed_generator
		raise ArgumentError, "cannot deduce a task and/or a generator from #{failure_point}"
	    end

            super("")
	end

        def pretty_print(pp)
	    pp.text "#{self.class.name}"
            if !message.empty?
                pp.text ": #{message}"
            end
            pp.breakable
            failure_point.pretty_print(pp)

            if backtrace && !backtrace.empty?
                Roby.pretty_print_backtrace(pp, backtrace)
            end
        end

        # True if +obj+ is involved in this error
        def involved_plan_object?(obj)
            obj.kind_of?(PlanObject) && 
                (obj == failed_event ||
                 obj == failed_generator ||
                 obj == failed_task)
        end
    end

    # Raised during event propagation if a task event is called or emitted,
    # while this task is not executable.
    class TaskNotExecutable < LocalizedError; end
    # Raised during event propagation if an event is called or emitted,
    # while this event is not executable.
    class EventNotExecutable < LocalizedError; end
    # Raised during event propagation if an event is called, while this event
    # is not controlable.
    class EventNotControlable < LocalizedError; end

    # Raised when an operation is attempted while the ownership does not allow
    # it.
    class OwnershipError < RuntimeError; end
    class RemotePeerMismatch < RuntimeError; end

    # Raised when a consistency check failed in the Roby internal code
    class InternalError < RuntimeError; end
    # Raised when a consistency check failed in the Roby propagation code
    class PropagationError < InternalError; end

    # Some operations need to be performed in the control thread, and some
    # other (namely blocking operations) must not. This exception is raised
    # when this constraint is not met.
    class PhaseMismatch < RuntimeError; end

    # Some operations need to be performed in the control thread, and some
    # other (namely blocking operations) must not. This exception is raised
    # when this constraint is not met.
    class ThreadMismatch < RuntimeError; end

    # Raised when a user-provided code block (i.e. a code block which is
    # outside of Roby's plan management algorithms) has raised. This includes:
    # event commands, event handlers, task polling blocks, ...
    class CodeError < LocalizedError
        # The original exception object
	attr_reader :error
        # Create a CodeError object from the given original exception object, and
        # with the given failure point
	def initialize(error, *args)
	    if error && !error.kind_of?(Exception)
		raise TypeError, "#{error} should be an exception"
	    end
	    super(*args)
	    @error = error
	end

	def pretty_print(pp) # :nodoc:
	    if error
                pp.text "#{self.class.name}: user code raised an exception "
                failure_point.pretty_print(pp)
                pp.breakable
                pp.breakable
                error.pretty_print(pp)
	    else
		super
	    end
	end
    end

    # Raised if a command block has raised an exception
    class CommandFailed < CodeError; end
    # Raised when the call of an event has been canceled.
    # See EventGenerator#cancel.
    class EventCanceled < LocalizedError; end
    # Raised when an event is called, but one of
    # its precondition is not met. See EventGenerator#precondition
    class EventPreconditionFailed < LocalizedError; end
    # Raised when the emission of an event has failed.
    # See EventGenerator#emit_failed.
    class EmissionFailed < CodeError; end
    # Raised when an event handler has raised.
    class EventHandlerError < CodeError; end

    # Raised when an exception handler has raised.
    class FailedExceptionHandler < CodeError
	attr_reader :handled_exception
	def initialize(error, object, handled_exception)
	    super(error, object)
	    @handled_exception = handled_exception
	end
    end

    # Raised when an event has become unreachable while other parts of the plan
    # where waiting for its emission.
    class UnreachableEvent < LocalizedError
        # The generator which has become unreachable
	attr_reader :generator
        # Create an UnreachableEvent error for the given +generator+. +reason+
        # is supposed to be either nil or a plan object which is the reason why
        # +generator+ has become unreachable.
	def initialize(generator, reason)
	    @generator = generator
	    super(reason || generator)
	end

	def pretty_print(pp) # :nodoc:
            pp.text "#{generator} has become unreachable"
	    if failure_point
		pp.breakable ':'
                failure_point.pretty_print(pp)
            end
	end
    end
    
    # Exception raised when the event loop aborts because of an unhandled
    # exception
    class Aborting < RuntimeError
	attr_reader :all_exceptions
	def initialize(exceptions)
            @all_exceptions = exceptions 
            super("")
        end
        def pretty_print(pp) # :nodoc:
            pp.text "control loop aborting because of unhandled exceptions"
            pp.seplist(",") do
                all_exceptions.pretty_print(pp)
            end
        end
	def backtrace # :nodoc:
            [] 
        end
    end

    # Raised by Plan#replace when the new task cannot replace the older one.
    class InvalidReplace < RuntimeError
        # The task being replaced
	attr_reader :from
        # The task which should have replaced #from
        attr_reader :to

        # Create a new InvalidReplace object
	def initialize(from, to)
	    @from, @to = from, to
	end
        def pretty_print(pp) # :nodoc:
            pp.text "invalid replacement: #{message}"
            pp.breakable
            pp.text "from "
            from.pretty_print(pp)
            pp.breakable
            pp.text "to "
            to.pretty_print(pp)
        end
    end
    
    # Exception raised when a mission has failed
    class MissionFailedError < LocalizedError
        # Create a new MissionFailedError for the given mission
	def initialize(task)
	    super(task.failure_event || task)
	end

        def pretty_print(pp)
            pp.text "mission failed: "
            super
        end
    end

    # Exception raised in threads which are waiting for the control thread
    # See for instance Roby.execute
    class ExecutionQuitError < RuntimeError; end
end

