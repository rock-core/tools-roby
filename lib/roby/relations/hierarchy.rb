require 'set'
module Roby::TaskRelationships
    module Hierarchy
        class RealizedByHash # :nodoc:
            def []=(task, event)
                task.send(:realizes) << task
            end
            def delete(task)
                task.send(:realizes).delete(task)
            end
        end
        
        attr_reader :realized_by
        def initialize(*args, &proc)
            @realizes    = Set.new
            @realized_by = RealizedByHash.new

            # Add us in the 'realizes' hash of the child
            def @realized_by.[]=(task, events)
                task.realizes << self
                super
            end

            # Remove us from the 'realizes' hash of the child
            def @realized_by.delete(task)
                task.realizes.delete(self)
                super
            end

            super
        end

        # Iterates on all parent tasks
        def each_parent(&iter); realizes.each(&iter) end
        # Iterates on all child task
        def each_child(&iter); realized.each_key(&iter) end

    private
        attr_reader :realizes
    end
end

