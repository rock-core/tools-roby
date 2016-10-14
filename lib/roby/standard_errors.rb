class Exception
    def self.match
        Roby::CodeError.match.with_ruby_exception(self)
    end

    def self.to_execution_exception_matcher
        match.to_execution_exception_matcher
    end

    def pretty_print(pp)
        pp.text "#{message} (#{self.class.name})"
    end
    
    # True if +obj+ is involved in this error
    def involved_plan_object?(obj)
        false
    end

    def user_error?; false end
end

module Roby
    # Exception base used for all errors that show an inconsistency inside Roby
    # itself
    class InternalError < RuntimeError; end

    # Module used to tag exceptions that "wrap" an original error from the user
    # code
    #
    # All such exceptions must give access to the original error by defining an
    # original_exceptions accessor
    module UserExceptionWrapper; end

    # Base class for all Roby exceptions
    class ExceptionBase < RuntimeError
        # List of Exception objects that caused this
        #
        # @return [Array<Exception>]
        attr_accessor :original_exceptions

        def initialize(exceptions = Array.new)
            @original_exceptions = exceptions
        end

        def report_exceptions_from(object)
            if object.kind_of?(Exception)
                original_exceptions << object
            elsif object.respond_to?(:report_exceptions_on)
                object.report_exceptions_on(self)
            elsif object.respond_to?(:context) && object.context
                object.context.each do |c|
                    report_exceptions_from(c)
                end
            elsif object.respond_to?(:failure_reason)
                report_exceptions_from(object.failure_reason)
            end
        end
    end

    # This kind of errors are generated during the plan execution, allowing to
    # blame a fault on a plan object (#failure_point). The precise failure
    # point is categorized in the #failed_event, #failed_generator and
    # #failed_task. It is guaranteed that one of #failed_generator and
    # #failed_task is non-nil.
    class LocalizedError < ExceptionBase
        # If true, such an exception causes the execution engine to stop tasks
        # in the hierarchy. Otherwise, it only causes notification(s).
        def fatal?; true end
        # The object describing the point of failure
	attr_reader :failure_point
        
        # The objects of the given categories which are related to #failure_point
        attr_reader :failed_event, :failed_generator, :failed_task

        # Create a LocalizedError object with the given failure point
        def initialize(failure_point)
            super()
	    @failure_point = failure_point

            @failed_task, @failed_event, @failed_generator = nil
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

            if failed_event
                failed_event.protect_all_sources
            end
	end

        def to_execution_exception
            ExecutionException.new(self)
        end

        def pretty_print(pp)
	    pp.text "#{self.class.name}"
            if !message.empty?
                pp.text ": #{message}"
            end
            pp.breakable
            failure_point.pretty_print(pp)
        end

        # True if +obj+ is involved in this error
        def involved_plan_object?(obj)
            obj.kind_of?(PlanObject) && 
                (obj == failed_event ||
                 obj == failed_generator ||
                 obj == failed_task)
        end

        # @return [Queries::ExecutionExceptionMatcher]
        def self.to_execution_exception_matcher
            Roby::Queries::ExecutionExceptionMatcher.new.with_model(self)
        end
        # @return [Queries::LocalizedErrorMatcher]
        def self.match
            Roby::Queries::LocalizedErrorMatcher.new.with_model(self)
        end
    end

    class RelationFailedError < LocalizedError
        # The parent in the failed relation
        attr_reader :parent
    end


    # Exception class used when trying to perform an operation on a finalized
    # object and the operation requires a plan
    class FinalizedPlanObject < RuntimeError; end
    # Raised during event propagation if a task event is called or emitted,
    # while this task is not executable.
    class TaskNotExecutable < LocalizedError; end
    # Raised during event propagation if an event is called or emitted,
    # while this event is not executable.
    class EventNotExecutable < LocalizedError; end
    # Same error than EventNotExecutable, but for task events
    #
    # The only difference is that this method displays some task-specific
    # information
    class TaskEventNotExecutable < EventNotExecutable
        def initialize(failure_point)
            super(failure_point)
            if !(@plan = failed_generator.task.plan)
                @removed_at = failed_generator.task.removed_at
            end
        end

        def plan; @plan end
        def removed_at; @removed_at end

        def pretty_print(pp)
            pp.text "#{failed_generator.symbol} called but it is not executable on"
            pp.breakable
            failed_generator.task.pretty_print(pp)
            pp.breakable
            if plan
                pp.text "the task has NOT been garbage collected"
            elsif removed_at
                pp.text "#{failed_generator.task} has been removed from its plan at"
                removed_at.each do |line|
                    pp.breakable
                    pp.text "  #{line}"
                end
            else
                pp.text "the task has never been included in a plan"
            end
        end
    end
    # Raised when an error occurs on a task while we were terminating it
    class TaskEmergencyTermination < LocalizedError
        attr_reader :reason

        def quarantined?
            !!@quarantined
        end

        def initialize(task, reason, quarantined = false)
            super(task)

            @quarantined = quarantined
            @reason = reason
            report_exceptions_from(reason)
        end

        def pretty_print(pp)
            pp.text "The following task is being terminated because of an internal error"
            pp.breakable
            if quarantined?
                pp.text "It has been put under quarantine"
            else
                pp.text "It is not yet put under quarantine"
            end
            pp.breakable
            super
            pp.breakable
            if !original_exceptions.include?(reason)
                reason.pretty_print(pp)
            end
        end
    end

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
        include UserExceptionWrapper

        # The original exception object
        def original_exception; original_exceptions.first end
        # @deprecated use {#original_exception} instead
        def error; original_exception end
        # Create a CodeError object from the given original exception object, and
        # with the given failure point
	def initialize(error, *args)
	    if error && !error.kind_of?(Exception)
		raise TypeError, "#{error} should be an exception"
	    end
	    super(*args)
            report_exceptions_from(error)
	end

        def pretty_print(pp)
            pp.text "#{self.class.name}: user code raised an exception "
            failure_point.pretty_print(pp)
        end

        def self.match
            Roby::Queries::CodeErrorMatcher.new.with_model(self)
        end
    end

    # Raised when a command is being processed, but it cannot be (e.g. because
    # of task state)
    class CommandRejected < LocalizedError; end

    # Raised when an event's emission has being requested, but it cannot be
    # (e.g. because of task state)
    class EmissionRejected < LocalizedError; end

    # Raised if a command block has raised an exception
    class CommandFailed < CodeError
        def pretty_print(pp)
            pp.text "uncaught exception in the command of the "
            failed_generator.pretty_print(pp)
            pp.text " (#{self.class})"
        end
    end
    # Raised during event propagation if an event is called, while this event
    # is not controlable.
    class EventNotControlable < LocalizedError; end
    # Raised when the call of an event has been canceled.
    # See EventGenerator#cancel.
    class EventCanceled < LocalizedError; end
    # Raised when an event is called, but one of
    # its precondition is not met. See EventGenerator#precondition
    class EventPreconditionFailed < LocalizedError; end
    # Raised when the emission of an event has failed.
    # See EventGenerator#emit_failed.
    class EmissionFailed < CodeError
        def initialize(*args, &block)
            super
            if !failed_generator
                raise ArgumentError, "creating an EmissionFailed error without a generator"
            end
        end

	def pretty_print(pp) # :nodoc:
            pp.text "failed emission of the "
            failed_generator.pretty_print(pp)
            pp.text " (#{self.class})"
	end
    end
    # Raised when an event handler has raised.
    class EventHandlerError < CodeError
        def pretty_print(pp)
            pp.text "uncaught exception in an event handler of the "
            failed_generator.pretty_print(pp)
            pp.text " (#{self.class})"
            pp.breakable
            pp.text "called during the propagation of "
            failed_event.pretty_print(pp)
        end
    end

    # Raised when an exception handler has raised.
    class FailedExceptionHandler < CodeError
	attr_reader :handled_exception
        attr_reader :handler

	def initialize(error, object, handled_exception, handler)
	    super(error, object)
	    @handled_exception = handled_exception
            @handler = handler
	end

        def pretty_print(pp)
            pp.text "exception handler #{handler} failed while processing"
            pp.breakable
            handled_exception.pretty_print(pp)
        end
    end

    # Raised when an event has become unreachable while other parts of the plan
    # where waiting for its emission.
    class UnreachableEvent < LocalizedError
        # Why did the generator become unreachable
        attr_reader :reason

        # Create an UnreachableEvent error for the given +generator+. +reason+
        # is supposed to be either nil or a plan object which is the reason why
        # +generator+ has become unreachable.
	def initialize(generator, reason)
	    super(generator)
            @reason    = reason
            report_exceptions_from(reason)
	end

	def pretty_print(pp) # :nodoc:
            pp.text "#{failed_generator} has become unreachable"
	    if reason
                reason = [*reason]
                reason.each do |e|
                    pp.breakable
                    e.pretty_print(pp)
                end
            end
	end
    end
    
    # Exception raised when the event loop aborts because of an unhandled
    # exception
    class Aborting < ExceptionBase
        def pretty_print(pp) # :nodoc:
            pp.text "control loop aborting because of unhandled exceptions"
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
    class ToplevelTaskError < LocalizedError
        include UserExceptionWrapper

        attr_reader :reason

        # Create a new MissionFailedError for the given mission
        def initialize(task, reason = nil)
            super(task.failure_event || task)
            @reason = reason || task.failure_reason
            report_exceptions_from(@reason)
	end

        def pretty_print(pp)
            if reason
                reason.pretty_print(pp)
            elsif failed_event
                failed_event.pretty_print(pp)
            else
                explanation = :success.to_unbound_task_predicate.explain_static(failed_task)
                explanation.pretty_print(pp)
            end
        end
    end

    # Exception raised when a mission has failed
    class MissionFailedError < ToplevelTaskError
        def pretty_print(pp)
            pp.text "mission failed: "
            failed_task.pretty_print(pp)
            pp.breakable
            super(pp)
        end
    end

    # Exception raised when a permanent task has failed
    class PermanentTaskError < ToplevelTaskError
        def fatal?; false end
        def pretty_print(pp)
            pp.text "permanent task failed: "
            failed_task.pretty_print(pp)
            pp.breakable
            super(pp)
        end
    end

    # Exception raised in threads which are waiting for the control thread
    # See for instance Roby.execute
    class ExecutionQuitError < RuntimeError; end

    # Exception raised when a child is being resolved by role, but the role is
    # not associated with any child
    class NoSuchChild < ArgumentError
        # @return [Object] the object whose children we try to access
        attr_reader :object
        # @return [String] the role that failed to be resolved
        attr_reader :role
        # @return [{String=>Object}] the set of known children
        attr_reader :known_children

        def initialize(object, role, known_children)
            @object, @role, @known_children = object, role, known_children
        end

        def pretty_print(pp)
            pp.text "#{object} has no child with the role '#{role}'"

            if known_children.empty?
                pp.text ", actually, it has no child at all"
            else
                pp.text ". Known children:"
                pp.nest(2) do
                    known_children.each do |role, child|
                        pp.breakable
                        pp.text "#{role}: #{child}"
                    end
                end
            end
        end
    end
end

