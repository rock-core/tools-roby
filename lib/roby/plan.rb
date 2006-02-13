require 'set'
require 'roby/relations/hierarchy'

module Roby
    class Task
        include TaskRelations::Hierarchy
    end

    class Plan
        def initialize
            @tasks = Set.new
        end
        def each_task(&iter); tasks.each(&iter) end

        def insert(task)
            @tasks << task
        end

        def display
        end
    end
end

