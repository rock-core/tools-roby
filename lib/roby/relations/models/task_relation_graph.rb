module Roby
    module Relations
        module Models
            module TaskRelationGraph
                # If true, the tasks that have a parent in this relation will still be
                # available for scheduling. Otherwise, they won't get scheduled
                attr_predicate :scheduling?, true

                def setup_submodel(submodel, scheduling: true, **options)
                    super(submodel, **options)
                    submodel.scheduling = scheduling
                end
            end
        end
    end
end


