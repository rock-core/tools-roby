
module Roby::TaskStructure
    class Roby::TaskEventGenerator
	# Mark this event as being handled by the task +task+
	def handle_with(repairing_task)
	    if !task.child_object?(repairing_task, ErrorHandling)
		task.add_error_handler repairing_task, ValueSet.new
	    end

	    task[repairing_task, ErrorHandling] << symbol
	end
    end

    module ErrorHandlingSupport
	def failed_task
	    each_parent_object(ErrorHandling) do |task|
		return task
	    end
	    nil
	end
    end

    relation :ErrorHandling, :child_name => :error_handler
end

