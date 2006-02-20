require 'enumerator'
require 'roby/relations'
require 'set'

module Roby::TaskStructure
    module Hierarchy
        include Roby::TaskStructure::Interface

        def initialize(*args, &proc)
            @realizes    = Set.new
            @realized_by = Hash.new
            super
        end

        HierarchyLink = Struct.new(:done_with, :fails_on)
         
        # Return an array of the task for which the :start event is not
        # signalled by a child event
        def first_children
            alone = Hash.new
            enum_bfs(:each_child) do |child, _|
                alone[child] = true
                child.each_event do |source|
                    source.each_signal { |signalled|
                        alone[signalled.task] = false if signalled.symbol == :start
                    }
                end
            end
            alone.keys.find_all { |task| alone[task] }
        end

        def realized_by(task, options = {:done_with => :stop})
            options = validate_options(options, HierarchyLink.members)
            new_relation = HierarchyLink.new([*options[:done_with]], [*options[:fails_on]])
            
            @realized_by[task] = new_relation
            task.realizes << self
            added_task_relation(Hierarchy, self, task, new_relation)
            task.added_task_relation(Hierarchy, self, task, new_relation)
            self
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
            self
        end
        def self.delete(first, second)
            first.remove_hierarchy(second) # remove_hierarchy is symmetric
        end

        # If the given task is one of our parents
        def realizes?(task); @realizes.include?(task) end

        # If the given task is one of our children. If
        # +options+ is provided, it is checked for inclusion.
        # See #realized_by for valid options
        def realized_by?(task, options = nil)
            options = validate_options(options, HierarchyLink.members)
            return false unless events = @realized_by[task]
            return true unless options
            
            options.each do |kind, value|
                value = [*value]
                return false unless value.all? { |v| events[kind].include?(v) }
            end
            return true
        end

        # Iterates on all parent tasks
        def each_parent(&iter); realizes.each(&iter) end
        # Iterates on all child tasks
        def each_child(&iter); @realized_by.each_key(&iter) end

    protected
        attr_reader :realizes
    end
end

module Roby
    class Task
        include TaskStructure::Hierarchy
    end
end

