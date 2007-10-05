module Roby
    class LocalizedError < RuntimeError
	attr_reader :failure_point, :failed_event, :failed_generator, :failed_task
	attr_reader :user_message

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

	def message
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

	def exception(user_message = nil)
	    new_error = dup
	    new_error.instance_variable_set(:@user_message, user_message)
	    new_error
	end
    end

    # Base class for all violations related to models
    class TaskNotExecutable < LocalizedError; end
    class EventNotExecutable < LocalizedError; end
    class EventNotControlable < LocalizedError; end

    class OwnershipError < RuntimeError; end
    class RemotePeerMismatch < RuntimeError; end

    class InternalError < RuntimeError; end
    class PropagationError < InternalError; end

    class ThreadMismatch < RuntimeError; end

    class CodeError < LocalizedError
	attr_reader :error
	def initialize(error, *args)
	    if error && !error.kind_of?(Exception)
		raise TypeError, "#{error} should be an exception"
	    end
	    super(*args)
	    @error = error
	end

	def message
	    if error
		"#{self.class} in #{failure_point}: #{error.message} (#{error.class})"
	    else
		super
	    end
	end

	def full_message
	    if error
		message + "\n  #{super}"
	    else
		super
	    end
	end
    end


    class CommandFailed < CodeError; end
    class EventCanceled < LocalizedError; end
    class EventPreconditionFailed < LocalizedError; end
    class EmissionFailed < CodeError; end
    class EventHandlerError < CodeError; end

    class FailedExceptionHandler < CodeError
	attr_reader :handled_exception
	def initialize(error, object, handled_exception)
	    super(error, object)
	    @handled_exception = handled_exception
	end
    end

    class UnreachableEvent < LocalizedError
	attr_reader :generator
	def initialize(generator, reason)
	    @generator = generator
	    super(reason || generator)
	end

	def message
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
	def message
	    "#{super}\n  " +
		all_exceptions.
		    map { |e| e.exception.full_message }.
		    join("\n  ")
	end
	def full_message; message end
	def backtrace; [] end
    end

    class InvalidReplace < RuntimeError
	attr_reader :from, :to, :error
	def initialize(from, to, error)
	    @from, @to, @error = from, to, error
	end
	def message
	    "#{error} while replacing #{from} by #{to}"
	end
    end
    
    # Exception raised when a mission has failed
    class MissionFailedError < LocalizedError
	def initialize(task)
	    super(task.terminal_event)
	end

	def message
	    "mission #{failed_task} failed with #{super}"
	end
    end

    # Exception raised in threads which are waiting for the control thread
    # See for instance Roby.execute
    class ControlQuitError < RuntimeError; end
end

