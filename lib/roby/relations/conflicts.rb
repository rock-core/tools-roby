module Roby
    module TaskStructure
        class << Roby::Task
            extend MetaRuby::Attributes
            inherited_attribute(:conflicting_model, :conflicting_models) { ValueSet.new }
        end
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
		klass.extend TaskStructure::ModelConflicts
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

	    models = task.class.conflicting_models
            for model in models
		for t in plan.find_tasks(model)
                    if t.running? && t != task
                        result << t
                    end
		end
	    end

	    if result
		plan.control.conflict(task, result)
	    end

	    # Add the needed conflict relations
	    models = task.class.conflicting_models
            for model in models
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

