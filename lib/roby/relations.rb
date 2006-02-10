module Roby
    module TaskRelationships
        # There is one kind of relation by module in Roby::TaskRelationships
        # These modules are included in tasks which need a given relation type
        module Interface
            # Iterates on all relation this task is involved in
            def each_relation(kind = nil); end
            # Is self related to +task+ ?
            def related?(task); false end

            # Should also define self.delete(a_task, another_task)
            # to remove all relations of the module's kind between
            # two task instances
            
            # Callback called by the relationship modules
            # when a relation involving self is created
            def added_task_relationship(kind, first_task, second_task, args); end
            # Callback called by the relationship modules
            # when a relation involving self is removed
            def removed_task_relationship(kind, first_task, second_task, args); end
        end
    end

    class Task
        # Must be the first of all TaskRelationships included
        include TaskRelationships::Interface
        
        # Removes all relations of the given kind between this task and other
        # Returns true if there was something to remove
        def remove_relation(kind, other)
            kind.delete(self, other)
        end
    end
end

