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
        # The user message
	attr_reader :user_message

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
	end

	def message # :nodoc:
	    base_msg = "#{self.class.name} in #{failure_point.to_s}: #{user_message}"
	    if failed_event && failed_event.context
		failed_event.context.each do |error|
		    if error.kind_of?(Exception)
			base_msg << "\n  * #{error.message}:\n    #{Roby.filter_backtrace(error.backtrace).join("\n    ")}"
		    end
		end
	    end

	    base_msg
	end

	def exception(user_message = nil) # :nodoc:
	    new_error = dup
            new_error.instance_variable_set(:@user_message, user_message)
	    new_error
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

	def message # :nodoc:
	    if error
		"#{self.class} in #{failure_point}: #{error.message} (#{error.class})\n  #{Roby.filter_backtrace(error.backtrace).join("\n  ")}"
	    else
		super
	    end
	end

	def full_message # :nodoc:
	    if error
		message + "\n  #{super}"
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

	def message # :nodoc:
	    if failure_point
		"#{generator} has become unreachable: #{failure_point}"
	    else
		"#{generator} has become unreachable"
	    end
	end
    end
    
    # Exception raised when the event loop aborts because of an unhandled
    # exception
    class Aborting < RuntimeError
	attr_reader :all_exceptions
	def initialize(exceptions); @all_exceptions = exceptions end
	def message # :nodoc:
	    "#{super}\n  " +
		all_exceptions.
		    map { |e| e.exception.full_message }.
		    join("\n  ")
	end
	def full_message # :nodoc:
            message 
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
        # A description of the replacement failure
        attr_reader :error

        # Create a new InvalidReplace object
	def initialize(from, to, error)
	    @from, @to, @error = from, to, error
	end
	def message # :nodoc:
	    "#{error} while replacing #{from} by #{to}"
	end
    end
    
    # Exception raised when a mission has failed
    class MissionFailedError < LocalizedError
        # Create a new MissionFailedError for the given mission
	def initialize(task)
	    super(task.terminal_event)
	end

	def message # :nodoc:
	    "mission #{failed_task} failed with #{super}"
	end
    end

    # Exception raised in threads which are waiting for the control thread
    # See for instance Roby.execute
    class ControlQuitError < RuntimeError; end
end

