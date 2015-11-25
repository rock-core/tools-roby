module Roby
    module TaskStructure
	relation :Conflicts, noinfo: true

        class Conflicts
            module Extension
                def conflicts_with(task)
                    # task.event(:stop).add_precedence event(:start)
                    add_conflicts(task)
                end
            end

            module ModelExtension
                extend MetaRuby::Attributes
                inherited_attribute(:conflicting_model, :conflicting_models) { Set.new }

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

            module EventGeneratorExtension
                def calling(context)
                    super if defined? super
                    return unless symbol == :start

                    # Check for conflicting tasks
                    result = Set.new
                    task.each_conflicts do |conflicting_task|
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

                    if !result.empty?
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
        end
    end

    Roby::TaskEventGenerator.include TaskStructure::Conflicts::EventGeneratorExtension
end

