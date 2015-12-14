module Roby
    module Relations
        # Subclass of Relations::Space for events. Its main usage is to keep track of
        # which tasks are related in a given relation through their events.
        #
        # I.e. if events 'a' and 'b' are parts of the tasks ta and tb, and 
        #
        #   a -> b
        #
        # in this relation graph, then 
        #
        #   relation.related_tasks?(ta, tb)
        #
        # will return true
        class EventRelationGraph < Relations::Graph
        end
    end
end

