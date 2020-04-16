# frozen_string_literal: true

module Roby
    module Relations
        # Subclass of Relations::Space for tasks.
        #
        # It adds attributes that are specific to tasks
        class TaskRelationGraph < Relations::Graph
            extend Models::TaskRelationGraph

            # If true, the tasks that have a parent in this relation will still be
            # available for scheduling. Otherwise, they won't get scheduled
            attr_predicate :scheduling?, true

            def initialize(scheduling: self.class.scheduling?, **options)
                super(**options)
                @scheduling = scheduling
            end
        end
    end
end
