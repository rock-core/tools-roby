require 'enumerator'
require 'roby/relations'
require 'set'

module Roby::TaskStructure
    relation Hierarchy do
	relation_name :child

        HierarchyLink = Struct.new(:done_with, :fails_on)
         
	def realizes?(obj);	parent_object?(obj, Hierarchy) end
	def realized_by?(obj);  child_object?(obj, Hierarchy) end
        def realized_by(task, options = {:done_with => :stop})
            options = validate_options(options, HierarchyLink.members)

            new_relation = HierarchyLink.new([*options[:done_with]], [*options[:fails_on]])
	    add_child(task, new_relation)
            self
        end

        # Return an array of the task for which the :start event is not
        # signalled by a child event
        def first_children
            alone = Hash.new
            enum_bfs(:each_child) do |child, info|
                alone[child] = true
                child.each_event do |source|
                    source.each_causal { |caused|
                        alone[caused.task] = false if caused.symbol == :start
                    }
                end
            end
            alone.keys.find_all { |task| alone[task] }
        end

    protected
        attr_reader :realizes
    end
end

