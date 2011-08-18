module Roby
    module TaskStructure
	relation :Influence, :child_name => 'influenced_task', :noinfo => true, :weak => true do
	    def influenced_by(task)
                if task.respond_to?(:as_plan)
                    task = task.as_plan
                end

		add_influenced_task(task)
		task
	    end
        end

    end
end

