
module Roby
    module TaskStructure
	Roby::Task.inherited_enumerable(:conflicting_model, :conflicting_models) { ValueSet.new }

        module ConflictsSupport
            module ClassExtension
                def conflicts_with(model)
                    conflicting_models << model
                    model.conflicting_models << self
                end

                def conflicts_with?(model)
                    each_conflicting_model do |m|
                        return true if m == model
                    end
                    false
                end
            end

	    def conflicts_with(task)
		task.event(:stop).add_precedence event(:start)
		add_conflicts(task)
	    end
        end
	relation :Conflicts, :noinfo => true
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
		Roby.decision_control.conflict(task, result)
	    end

	    # Add the needed conflict relations
	    models = task.class.conflicting_models
	    for model in models
		if candidates = plan.task_index.by_model[model]
		    for t in candidates
			t.conflicts_with task if t.pending?
		    end
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

