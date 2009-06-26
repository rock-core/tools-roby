module Roby
    module Schedulers
	class Basic
	    attr_reader :query
            attr_reader :include_children
	    def initialize(include_children = false)
                @include_children = include_children
		@query = Roby.plan.find_tasks.
		    executable.
		    pending.
		    self_owned
	    end
	    def initial_events
		query.reset.each do |task|
		    next unless task.event(:start).root? && task.event(:start).controlable?
		    root_task = task.enum_for(:each_relation).all? do |rel|
			if task.root?(rel)
			    true
			elsif rel == TaskStructure::PlannedBy 
			    task.planned_tasks.all? { |t| !t.executable? }
			end
		    end

		    if root_task || (include_children && task.parents.any? { |t| t.running? })
                        Robot.info "scheduler starts #{task}"
			task.start!
		    end
		end
	    end
	end
    end
end

