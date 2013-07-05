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
                    if task.child_object?(repairing_task, ErrorHandling)
                        symbol_set = task[repairing_task, ErrorHandling]
                        symbol_set.delete(symbol)
                        if symbol_set.empty?
                            task.remove_error_handler(repairing_task)
                        end
                    end
                end
            end

	    task[repairing_task, ErrorHandling] << symbol
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
    end

    class ErrorHandlingGraphClass
        def merge_info(parent, child, opt1, opt2)
            opt1 | opt2
        end
    end

    ErrorHandling.scheduling = false
end

