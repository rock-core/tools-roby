# frozen_string_literal: true

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
            # Set of mission tasks
            attr_reader :mission_tasks
            # Set of permanent tasks
            attr_reader :permanent_tasks
            # Set of permanent events
            attr_reader :permanent_events

            STATE_PREDICATES = %I[
                pending? starting? running? finished? success? failed?
            ].freeze
            PREDICATES = STATE_PREDICATES.dup.freeze

            def initialize
                @by_model = Hash.new do |h, k|
                    set = Set.new
                    set.compare_by_identity
                    h[k] = set
                end
                @by_predicate = {}
                @by_predicate.compare_by_identity
                STATE_PREDICATES.each do |state_name|
                    set = Set.new
                    set.compare_by_identity
                    by_predicate[state_name] = set
                end
                @self_owned = Set.new
                @self_owned.compare_by_identity
                @by_owner = {}
                @by_owner.compare_by_identity
                @mission_tasks = Set.new
                @permanent_tasks = Set.new
                @permanent_events = Set.new
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

                @by_predicate = {}
                source.by_predicate.each do |state, set|
                    by_predicate[state] = set.dup
                end

                @self_owned = source.self_owned.dup

                @by_owner = {}
                source.by_owner.each do |owner, set|
                    by_owner[owner] = set.dup
                end
            end

            def clear
                @by_model.clear
                @by_predicate.each_value(&:clear)
                @by_owner.clear
                @self_owned.clear
                @mission_tasks.clear
                @permanent_tasks.clear
                @permanent_events.clear
            end

            # Add a new task to this index
            def add(task)
                task.model.ancestors.each do |klass|
                    by_model[klass] << task
                end
                PREDICATES.each do |pred|
                    by_predicate[pred] << task if task.send(pred)
                end
                self_owned << task if task.self_owned?
                task.owners.each do |owner|
                    add_owner(task, owner)
                end
            end

            # Updates the index to reflect that +new_owner+ now owns +task+
            def add_owner(task, new_owner)
                self_owned << task if task.self_owned?
                (by_owner[new_owner] ||= Set.new) << task
            end

            # Updates the index to reflect that +peer+ no more owns +task+
            def remove_owner(task, peer)
                if (set = by_owner[peer])
                    set.delete(task)
                    by_owner.delete(peer) if set.empty?
                end
                self_owned.delete(task) unless task.self_owned?
            end

            # Updates the index to reflect a change of state for +task+
            def set_state(task, new_state)
                STATE_PREDICATES.each do |state|
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
                task.model.ancestors.each do |klass|
                    set = by_model[klass]
                    set.delete(task)
                    by_model.delete(klass) if set.empty?
                end

                by_predicate.each do |state_set|
                    state_set.last.delete(task)
                end

                self_owned.delete(task)
                task.owners.each do |owner|
                    remove_owner(task, owner)
                end
            end
        end
    end
end
