module Roby
    module TaskStructure
        module InfluenceSupport
	    def influenced_by(task)
		add_influenced_task(task)
	    end
        end

	relation :Influence, :child_name => 'influenced_task', :noinfo => true, :weak => true
    end
end

