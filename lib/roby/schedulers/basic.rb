module Roby
    module Schedulers
	class Basic
            attr_reader :plan
	    attr_reader :query
            attr_reader :include_children
	    def initialize(include_children = false, plan = nil)
                @plan ||= Roby.plan
                @include_children = include_children
		@query = plan.find_tasks.
		    executable.
		    pending.
		    self_owned
	    end
	    def initial_events
		for task in query.reset
		    if !(task.event(:start).root? && task.event(:start).controlable?)
                        next
                    end

		    root_task =
                        if task.root?(TaskStructure::Dependency)
			    true
                        else
			    task.planned_tasks.all? { |t| !t.executable? }
			end

		    if root_task || (include_children && task.parents.any? { |t| t.running? })
			task.start!
		    end
		end
	    end
	end
    end
end

