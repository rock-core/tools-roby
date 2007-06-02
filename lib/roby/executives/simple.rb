module Roby
    module Executives
	class Simple
	    attr_reader :query
	    def initialize
		@query = Roby.plan.find_tasks.
		    executable.
		    pending
	    end
	    def initial_events
		query.reset.each do |task|
		    if task.root?(TaskStructure::Hierarchy) && task.event(:start).root?
			task.start!
		    end
		end
	    end
	end
    end
end

