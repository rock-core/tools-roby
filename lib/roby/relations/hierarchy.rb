require 'roby/relations'
require 'set'

module Roby::TaskRelations
    module Hierarchy
        def initialize(*args, &proc)
            @realizes    = Set.new
            @realized_by = Hash.new
            super
        end

        HierarchyLink = Struct.new(:done_with, :fails_on)

        def realized_by(task, options = nil)
            options = validate_options(options, :done_with => [:stop], :fails_on => [])

            @realized_by[task] = HierarchyLink.new([*options[:done_with]], [*options[:fails_on]])
            task.realizes << self
            added_task_relation(Hierarchy, self, task, @realized_by)
        end

        def remove_hierarchy(task)
            if events = @realized_by.delete(task)
                task.send(:realizes).delete(self)
                removed_task_relation(Hierarchy, self, task, events)
                task.removed_task_relation(Hierarchy, self, task, events)
                true
            elsif @realizes.include?(task)
                task.remove_hierarchy(self)
                true
            end
        end
        def self.delete(first, second)
            first.remove_hierarchy(second) # remove_hierarchy is symmetric
        end

        # If the given task is one of our parents
        def realizes?(task); @realizes.include?(task) end

        # If the given task is one of our children. If
        # +event+ is provided, checks that the event is
        # one of the exit conditions
        def realized_by?(task, event = nil)
            return false unless events = @realized_by[task]
            return true  unless event
            if events.respond_to?(:include?)
                events.include?(event)
            else
                true
            end
        end

        # Iterates on all parent tasks
        def each_parent(&iter); realizes.each(&iter) end
        # Iterates on all child tasks
        def each_child(&iter); @realized_by.each_key(&iter) end

        # See Interface::related?
        def related?(task)
            each_parent { |t| return true if t == task }
            each_child { |t| return true if t == task }
            super
        end

        # See Interface::each_relation
        # For Hierarchy relations, yields [Hierarchy, parent, child, events]
        def each_relation(kind = nil, &iter)
            return unless !kind || kind == Hierarchy
            @realizes.each do |task|
                events = task.send(:realized_by_hash)[self]
                yield(Hierarchy, task, self, events)
            end
            @realized_by.each do |task, events|
                yield(Hierarchy, self, task, events)
            end
            super
        end

    protected
        def realized_by_hash; @realized_by end
        attr_reader :realizes
    end
end

module Roby
    class Task
        include TaskRelations::Hierarchy
    end
end

