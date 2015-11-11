module Roby
    module Queries
    # Maintains a set of tasks as classified sets, speeding up query operations.
    #
    # @see {Roby::Plan#task_index} {Roby::Queries::Query}
    class Index
        # A model => Set map of the tasks for each model
	attr_reader :by_model
	# A state => Set map of tasks given their state. The state is
	# a symbol in [:pending, :starting, :running, :finishing,
	# :finished]
	attr_reader :by_predicate
	# A peer => Set map of tasks given their owner.
	attr_reader :by_owner

	STATE_PREDICATES = [:pending?, :running?, :finished?, :success?, :failed?].to_set
        PREDICATES = STATE_PREDICATES.dup

	def initialize
	    @by_model = Hash.new { |h, k| h[k] = Set.new }
	    @by_predicate = Hash.new
	    STATE_PREDICATES.each do |state_name|
		by_predicate[state_name] = Set.new
	    end
	    @by_owner = Hash.new
	end

        def initialize_copy(source)
            super
	    @by_model = Hash.new { |h, k| h[k] = Set.new }
            source.by_model.each do |model, set|
                by_model[model] = set.dup
            end

            @by_predicate = Hash.new
            source.by_predicate.each do |state, set|
                by_predicate[state] = set.dup
            end
            @by_owner = source.by_owner.dup
        end

        def clear
            @by_model.clear
            @by_predicate.each_value(&:clear)
            @by_owner.clear
        end

        # Add a new task to this index
	def add(task)
	    for klass in task.model.ancestors
		by_model[klass] << task
	    end
            for pred in PREDICATES
                if task.send(pred)
                    by_predicate[pred] << task
                end
            end
	    for owner in task.owners
		add_owner(task, owner)
	    end
	end

        # Updates the index to reflect that +new_owner+ now owns +task+
	def add_owner(task, new_owner)
	    (by_owner[new_owner] ||= Set.new) << task
	end

        # Updates the index to reflect that +peer+ no more owns +task+
	def remove_owner(task, peer)
	    if set = by_owner[peer]
		set.delete(task)
		if set.empty?
		    by_owner.delete(peer)
		end
	    end
	end

        # Updates the index to reflect a change of state for +task+
	def set_state(task, new_state)
            for state in STATE_PREDICATES
                by_predicate[state].delete(task)
	    end
            add_state(task, new_state)
	end

        def add_state(task, new_state)
	    add_predicate(task, new_state)
        end

        def remove_state(task, state)
            remove_predicate(task, state)
        end

        def add_predicate(task, predicate)
            by_predicate[predicate] << task
        end

        def remove_predicate(task, predicate)
	    by_predicate[predicate].delete(task)
        end


        # Remove all references of +task+ from the index.
	def remove(task)
	    for klass in task.model.ancestors
		by_model[klass].delete(task)
	    end
	    for state_set in by_predicate
		state_set.last.delete(task)
	    end
	    for owner in task.owners
		remove_owner(task, owner)
	    end
	end
    end
    end
end

