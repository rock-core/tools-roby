module Roby
    module TaskRelationships
        # There is one kind of relation by module in Roby::TaskRelationships
        # These modules are included in tasks which need the management of this
        # kind of relation
        module Interface
            def each_relation(kind = nil); end
            def related?(task); false end

            # Should also define self.delete(a_task, another_task)
            # to remove all relations of the module's kind between
            # two task instances
            
            # Callbacks called by the various relationship modules
            # each time a relation is added/removed
            def added_task_relationship(kind, first_task, second_task, args); end
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
 
