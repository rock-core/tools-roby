module Roby::TaskStructure
    class Roby::TaskEventGenerator
	# Mark this event as being handled by the task +task+
	def handle_with(repairing_task, options = Hash.new)
            options = Kernel.validate_options options,
                :remove_when_done => true

	    if !task.child_object?(repairing_task, ErrorHandling)
		task.add_error_handler repairing_task, ValueSet.new
	    end

            if options[:remove_when_done]
                repairing_task.on :stop do |event|
                    symbol_set = task[repairing_task, ErrorHandling]
                    symbol_set.delete(symbol)
                    if symbol_set.empty?
                        task.remove_error_handler(repairing_task)
                    end
                end
            end

	    task[repairing_task, ErrorHandling] << symbol
	end
    end

    relation :ErrorHandling, :child_name => :error_handler, :strong => true do
	def failed_task
	    each_parent_object(ErrorHandling) do |task|
		return task
	    end
	    nil
	end
    end
end

