module Roby::TaskStructure
    class Roby::TaskEventGenerator
	# Mark this event as being handled by the task +task+
	def handle_with(repairing_task, options = Hash.new)
            if repairing_task.respond_to?(:as_plan)
                repairing_task = repairing_task.as_plan
            end

            options = Kernel.validate_options options,
                :remove_when_done => true

	    if !task.child_object?(repairing_task, ErrorHandling)
		task.add_error_handler repairing_task, Set.new
	    end

            if options[:remove_when_done]
                repairing_task.on :stop do |event|
                    repairing_task = event.task
                    if task.child_object?(repairing_task, ErrorHandling)
                        matcher_sets = task[repairing_task, ErrorHandling]
                        matcher_sets.delete_if do |m|
                            m.matches_task?(event.task)
                        end
                        if matcher_sets.empty?
                            task.remove_error_handler(repairing_task)
                        end
                    end
                end
            end

	    task[repairing_task, ErrorHandling] << Roby::Queries::ExecutionExceptionMatcher.new.with_origin(task.model.find_event(symbol))
            repairing_task
	end
    end

    relation :ErrorHandling, :child_name => :error_handler, :strong => true

    module ErrorHandlingGraphClass::Extension
        def repaired_tasks
	    enum_parent_objects(ErrorHandling).to_a
        end

	def failed_task
            # For backward compatibility only. One should use #repaired_tasks
            repaired_tasks.first
	end

        # Tests if this task can be used to repair an exception
        #
        # It is different from {#repairs_error?} as the latter tests whether
        # this task is currently repairing such an exception, while this one only
        # tests if it could (usually, the difference is whether this task is
        # running)
        #
        # @return [Boolean]
        def can_repair_error?(exception)
            return if finished?

            exception = exception.to_execution_exception
            repaired_tasks.each do |repaired|
                matchers = repaired[self, ErrorHandling]
                if matchers.any? { |m| m === exception }
                    return true
                end
            end
            false
        end

        # Tests whether the given exception is handled by this task or by a
        # repair handler attached to this task
        def repairs_error?(exception)
            exception = exception.to_execution_exception
            running? && can_repair_error?(exception)
        end

        # Returns the set of repair tasks attached to self that match the given
        # exception
        def find_all_matching_repair_tasks(exception)
            exception = exception.to_execution_exception
            result = []
            each_error_handler do |child, matchers|
                next if child.finished?
                result << child if matchers.any? { |m| m === exception }
            end
            result
        end

        # Tests if this task can handle the provided exception, either because
        # it is an error repair task itself, or because it has one attached.
        #
        # It is different from {#handles_error?} as the latter tests whether
        # this task is currently handling the exception, while this one only
        # tests if it could (usually, the difference is whether this task is
        # running)
        #
        # @return [Boolean]
        def can_handle_error?(exception)
            exception = exception.to_execution_exception
            can_repair_error?(exception) ||
                !find_all_matching_repair_tasks(exception).empty?
        end

        # Tests if this task is currently handling the provided exception,
        # either because it is an error repair task itself, or because it has
        # one attached.
        #
        # @return [Boolean]
        def handles_error?(exception)
            exception = exception.to_execution_exception
            ((running? || starting?) && can_repair_error?(exception)) ||
                find_all_matching_repair_tasks(exception).any? { |t| t.starting? || t.running? }
        end

        # Test if this task has an active repair tasks associated
        def being_repaired?
            enum_child_objects(ErrorHandling).any? { |t| t.running? }
        end
    end

    class ErrorHandlingGraphClass
        def merge_info(parent, child, opt1, opt2)
            opt1 | opt2
        end
    end

    ErrorHandling.scheduling = false
end

