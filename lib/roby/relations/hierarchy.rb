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
            each_child(true) do |child|
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
        def each_child(whole_tree = false, &iter)
            queue = @realized_by.keys
            queue.each do |task|
                yield(task)
                task.each_child(true) { |child| queue << child } if whole_tree
            end
        end

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
        include TaskStructure::Hierarchy
    end
end

