require 'enumerator'
require 'roby/relations'
require 'set'

module Roby::TaskStructure
    relation :child do
	module_name :Hierarchy

	HierarchyLink = Struct.new :success, :failure
         
	def realizes?(obj);	parent_object?(obj, Hierarchy) end
	def realized_by?(obj);  child_object?(obj, Hierarchy) end

	# Adds +task+ as a child of +self+. You can specify a list of 'success' events
	# which mark the end of the relationship (i.e. the child task is no more
	# needed by the parent task), and a list of 'failure' events which are
	# not accepted by the parent task
	#
	# TODO: if :stop is not in :success, it shall be in :failure since
	# no event in :success can happen. In fact, it is more general. We
	# should make sure that the events in :success are reachable
        def realized_by(task, options = {:success => :stop})
            options = validate_options options, :success => [], :failure => [:failed]
	    options = options.inject({}) { |h, (k, v)| h[k] = [*v]; h }

	    success = options[:success].to_a.map { |ev| task.event(ev) }
	    failure = options[:failure].to_a.map { |ev| task.event(ev) }

	    failure.each do |event|
		event.until(event(:stop)).on { |event| emit(:failed, event.context) }
	    end

	    # if task.has_event?(:failed) && !options.has_key?(:failure)
	    #     options[:failure] = [:failed]
	    # end

	    add_child(task, HierarchyLink.new(success, failure))
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

