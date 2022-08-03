# frozen_string_literal: true

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
                    super
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

                    unless result.empty?
                        plan.control.conflict(task, result)
                        return
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
                    super

                    if symbol == :stop
                        task.relation_graph_for(Conflicts).remove_vertex(task)
                    end
                end
            end
        end

        # Class holding conflict error information
        #
        # Note that it is not an exception as a failed conflict is usually
        # handled by calling #failed_to_start! on the newly started task
        class ConflictError
            attr_reader :starting_task, :running_tasks

            def initialize(starting_task, running_tasks)
                @starting_task, @running_tasks = starting_task, running_tasks
            end

            def pretty_print(pp)
                pp.text "failed to start "
                starting_task.pretty_print(pp)
                pp.text "because it conflicts with #{running_tasks.size} running tasks"
                pp.nest(2) do
                    runnning_tasks.each do |t|
                        pp.breakable
                        t.pretty_print(pp)
                    end
                end
            end
        end
    end

    Roby::TaskEventGenerator.class_eval do
        prepend TaskStructure::Conflicts::EventGeneratorExtension
    end
end
