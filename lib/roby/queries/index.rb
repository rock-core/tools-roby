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
        # Tasks that are locally owned
        attr_reader :self_owned

        STATE_PREDICATES = [:pending?, :starting?, :running?, :finished?, :success?, :failed?].to_set
        PREDICATES = STATE_PREDICATES.dup

        def initialize
            @by_model = Hash.new { |h, k| h[k] = Set.new }
            @by_predicate = Hash.new
            STATE_PREDICATES.each do |state_name|
                by_predicate[state_name] = Set.new
            end
            @self_owned = Set.new
            @by_owner = Hash.new
        end

        def merge(source)
            source.by_model.each do |model, set|
                by_model[model].merge(set)
            end
            source.by_predicate.each do |state, set|
                by_predicate[state].merge(set)
            end
            self_owned.merge(source.self_owned)
            source.by_owner.each do |owner, set|
                (by_owner[owner] ||= Set.new).merge(set)
            end
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

            @self_owned = source.self_owned.dup

            @by_owner = Hash.new
            source.by_owner.each do |owner, set|
                by_owner[owner] = set.dup
            end
        end

        def clear
            @by_model.clear
            @by_predicate.each_value(&:clear)
            @by_owner.clear
            @self_owned.clear
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
            if task.self_owned?
                self_owned << task
            end
            for owner in task.owners
                add_owner(task, owner)
            end
        end

        # Updates the index to reflect that +new_owner+ now owns +task+
        def add_owner(task, new_owner)
            if task.self_owned?
                self_owned << task
            end
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
            if !task.self_owned?
                self_owned.delete(task)
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
                set = by_model[klass]
                set.delete(task)
                if set.empty?
                    by_model.delete(klass)
                end
            end
            for state_set in by_predicate
                state_set.last.delete(task)
            end
            self_owned.delete(task)
            for owner in task.owners
                remove_owner(task, owner)
            end
        end
    end
    end
end

