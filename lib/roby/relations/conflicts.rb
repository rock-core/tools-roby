module Roby
    module TaskStructure
	Roby::Task.inherited_enumerable(:conflicting_model, :conflicting_models) { ValueSet.new }
	module ModelConflicts
	    def conflicts_with(model)
		conflicting_models << model
		model.conflicting_models << self
	    end

	    def conflicts_with?(model)
		each_conflicting_model do |m|
		    return true if model <= m
		end
		false
	    end
	end
	Roby::Task.extend ModelConflicts

	relation :Conflicts, :noinfo => true do
	    def conflicts_with(task)
		# task.event(:stop).add_precedence event(:start)
		add_conflicts(task)
	    end

	    def self.included(klass) # :nodoc:
		klass.extend ModelConflicts
		super
	    end
	end
    end

    module ConflictEventHandling
	def calling(context)
	    super if defined? super
	    return unless symbol == :start

	    # Check for conflicting tasks
	    result = nil
	    task.each_conflicts do |conflicting_task|
		result ||= ValueSet.new
		result << conflicting_task
	    end

	    if result
		plan.control.conflict(task, result)
	    end

	    # Add the needed conflict relations
            task.class.each_conflicting_model do |model|
		for t in plan.find_tasks(model)
                    t.conflicts_with task if t.pending? && t != task
		end
	    end
	end
    
	def fired(event)
	    super if defined? super

	    if symbol == :stop
		TaskStructure::Conflicts.remove(task)
	    end
	end
    end
    Roby::TaskEventGenerator.include ConflictEventHandling
end

