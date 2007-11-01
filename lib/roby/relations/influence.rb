module Roby
    module TaskStructure
	relation :Influence, :child_name => 'influenced_task', :noinfo => true, :weak => true do
	    def influenced_by(task)
		add_influenced_task(task)
	    end
	end
    end
end

