module Roby
    # A plan that can be used for execution
    class ExecutablePlan < Plan
	extend Logger::Hierarchy
	extend Logger::Forward

        # The ExecutionEngine object which handles this plan. The role of this
        # object is to provide the event propagation, error propagation and
        # garbage collection mechanisms for the execution.
        attr_accessor :execution_engine

        # The ConnectionSpace object which handles this plan. The role of this
        # object is to sharing with other Roby plan managers
        attr_accessor :connection_space

        # @deprecated use {#execution_engine} instead
        def engine
            Roby.warn_deprecated "Plan#engine is deprecated, use #execution_engine instead"
            execution_engine
        end

        # The DecisionControl object which is associated with this plan. This
        # object's role is to handle the conflicts that can occur during event
        # propagation.
        def control; execution_engine.control end

	# A set of tasks which are useful (and as such would not been garbage
	# collected), but we want to GC anyway
	attr_reader :force_gc

	# A set of task for which GC should not be attempted, either because
	# they are not interruptible or because their start or stop command
	# failed
	attr_reader :gc_quarantine

        # Put the given task in quarantine. In practice, it means that all the
        # event relations of that task's events are removed, as well as its
        # children. Then, the task is added to gc_quarantine (the task will not
        # be GCed anymore).
        #
        # This is used as a last resort, when the task cannot be stopped/GCed by
        # normal means.
        def quarantine(task)
            task.each_event do |ev|
                ev.clear_relations
            end
            for rel in task.sorted_relations
                next if rel == Roby::TaskStructure::ExecutionAgent
                for child in task.child_objects(rel).to_a
                    task.remove_child_object(child, rel)
                end
            end
            Roby::ExecutionEngine.warn "putting #{task} in quarantine"
            gc_quarantine << task
            self
        end

        # Tests whether a task is in the quarantine
        #
        # @see #quarantine
        def quarantined_task?(task)
            gc_quarantine.include?(task)
        end

	# Check that this is an executable plan. This is always true for
	# plain Plan objects and false for transcations
	def executable?; true end

        def initialize(event_logger: DRoby::NullEventLogger.new)
            super(graph_observer: self, event_logger: event_logger)

            @execution_engine = ExecutionEngine.new(self)
	    @force_gc    = Set.new
	    @gc_quarantine = Set.new
            @exception_handlers = Array.new
            on_exception LocalizedError do |plan, error|
                plan.default_localized_error_handling(error)
            end
        end

        def refresh_relations
            super
            execution_engine.refresh_relations
        end

        def event_logger=(logger)
            super
            log :register_executable_plan, droby_id
        end

        def default_localized_error_handling(error)
            matching_handlers = Array.new
            active_fault_response_tables.each do |table|
                table.find_all_matching_handlers(error).each do |handler|
                    matching_handlers << [table, handler]
                end
            end
            handlers = matching_handlers.sort_by { |_, handler| handler.priority }

            while !handlers.empty?
                table, handler = handlers.shift
                if handler
                    begin
                        handler.activate(error, table.arguments)
                        return
                    rescue Exception => e
                        Robot.warn "ignored exception handler #{handler} because of exception"
                        Roby.log_exception_with_backtrace(e, Robot, :warn)
                    end
                end
            end

            error.each_involved_task.
                find_all { |t| mission_task?(t) && t != error.origin }.
                each do |m|
                    add_error(MissionFailedError.new(m, error.exception))
                end

            error.each_involved_task.
                find_all { |t| permanent_task?(t) && t != error.origin }.
                each do |m|
                    add_error(PermanentTaskError.new(m, error.exception))
                end

            pass_exception
        end

        # Calls the given block in the execution thread of this plan's engine.
        # If there is no engine attached to this plan, yields immediately
        #
        # See ExecutionEngine#execute
        def execute(&block)
            execution_engine.execute(&block)
        end

        def finalized_event(event)
            execution_engine.finalized_event(event)
            super
        end

        def unmark_mission_task(task)
            super
            execution_engine.needs_garbage_collection!
        end

        def unmark_permanent_task(task)
            super
            execution_engine.needs_garbage_collection!
        end

        def unmark_permanent_event(event)
            super
            execution_engine.needs_garbage_collection!
        end

        # Hook called before an edge gets added to this plan
        #
        # If an exception is raised, the edge will not be added
        #
        # @param [Object] parent the child object
        # @param [Object] child the child object
        # @param [Array<Class<Relations::Graph>>] relations the graphs in which an edge
        #   has been added
        # @param [Object] info the associated edge info that applies to
        #   relations.first
        def adding_edge(parent, child, relations, info)
            unless parent.read_write? || child.child.read_write?
		raise OwnershipError, "cannot remove a relation between two objects we don't own"
	    end

            if last_dag = relations.find_all(&:dag?).last
                if child.relation_graph_for(last_dag).reachable?(child, parent)
                    raise Relations::CycleFoundError, "adding an edge from #{parent} to #{child} would create a cycle in #{last_dag}"
                end
            end

            relations.each do |rel|
                if name = rel.child_name
                    parent.send("adding_#{rel.child_name}", child, info)
                    child.send("adding_#{rel.child_name}_parent", parent, info)
                end
            end

            for trsc in transactions
                next unless trsc.proxying?
                if (parent_proxy = trsc[parent, create: false]) && (child_proxy = trsc[child, create: false])
                    trsc.adding_plan_relation(parent_proxy, child_proxy, relations, info) 
                end
            end
        end

        # Hook called after a new edge has been added in this plan
        #
        # @param [Object] parent the child object
        # @param [Object] child the child object
        # @param [Array<Class<Relations::Graph>>] relations the graphs in which an edge
        #   has been added
        # @param [Object] info the associated edge info that applies to
        #   relations.first
        def added_edge(parent, child, relations, info)
            relations.each do |rel|
                if rel == Roby::EventStructure::Precedence
                    execution_engine.event_ordering.clear
                end

                if name = rel.child_name
                    parent.send("added_#{rel.child_name}", child, info)
                    child.send("added_#{rel.child_name}_parent", parent, info)
                end
            end

            log(:added_edge, parent, child, relations, info)
        end

        def updating_edge_info(parent, child, relation, info)
            emit_relation_change_hook(parent, child, relation, info, prefix: 'updating')
        end

        # Hook called when the edge information of an existing edge has been
        # updated
        #
        # @param parent the edge parent object
        # @param child the edge child object
        # @param [Class<Relations::Graph>] relation the relation graph ID
        # @param [Object] info the new edge info
        def updated_edge_info(parent, child, relation, info)
            emit_relation_change_hook(parent, child, relation, info, prefix: 'updated')
            log(:updated_edge_info, parent, child, relation, info)
        end

        # Hook called before an edge gets removed from this plan
        #
        # If an exception is raised, the edge will not be removed
        #
        # @param [Object] parent the parent object
        # @param [Object] child the child object
        # @param [Array<Class<Relations::Graph>>] relations the graphs in which an edge
        #   is being removed
        def removing_edge(parent, child, relations)
            unless parent.read_write? || child.child.read_write?
		raise OwnershipError, "cannot remove a relation between two objects we don't own"
	    end

            relations.each do |rel|
                if name = rel.child_name
                    parent.send("removing_#{rel.child_name}", child)
                    child.send("removing_#{rel.child_name}_parent", parent)
                end
            end

            for trsc in transactions
                next unless trsc.proxying?
                if (parent_proxy = trsc[parent, create: false]) && (child_proxy = trsc[child, create: false])
                    trsc.removing_plan_relation(parent_proxy, child_proxy, relations) 
                end
            end
        end

        # Hook called after an edge has been removed from this plan
        #
        # @param [Object] parent the child object
        # @param [Object] child the child object
        # @param [Array<Class<Relations::Graph>>] relations the graphs in which an edge
        #   has been removed
        def removed_edge(parent, child, relations)
            if parent.root_object? || child.root_object?
                execution_engine.needs_garbage_collection!
            end

            relations.each do |rel|
                if name = rel.child_name
                    parent.send("removed_#{rel.child_name}", child)
                    child.send("removed_#{rel.child_name}_parent", parent)
                end
            end

            log(:removed_edge, parent, child, relations)
        end

        # @api private
        def emit_relation_change_hook(parent, child, rel, *args, prefix: nil)
            if name = rel.child_name
                parent.send("#{prefix}_#{rel.child_name}", child, *args)
                child.send("#{prefix}_#{rel.child_name}_parent", parent, *args)
            end
        end

        # @api private
        #
        # Calls the added_* hook methods for all edges in a relation graph
        #
        # It is a helper for {#merged_plan}
        def emit_relation_graph_merge_hooks(graph, prefix: nil)
            rel = graph.class
            if rel.child_name
                added_child_hook  = "#{prefix}_#{rel.child_name}"
                added_parent_hook = "#{added_child_hook}_parent"
                graph.each_edge do |parent, child, info|
                    parent.send(added_child_hook, child, info)
                    child.send(added_parent_hook, parent, info)
                end
            end
        end

        # @api private
        #
        # Calls the added_ and adding_ hooks for modifications originating from
        # a transaction that involve tasks originally from the plan
        def emit_relation_graph_transaction_application_hooks(list, prefix: nil)
            hooks = Hash.new
            list.each do |graph, parent, child, *args|
                if !hooks.has_key?(graph)
                    rel = graph.class
                    if rel.child_name
                        parent_hook = "#{prefix}_#{rel.child_name}"
                        child_hook  = "#{parent_hook}_parent"
                        hooks[graph] = [parent_hook, child_hook]
                    else
                        hooks[graph] = nil
                    end
                end

                parent_hook, child_hook = hooks[graph]
                next if !child_hook

                parent.send(parent_hook, child, *args)
                child.send(child_hook, parent, *args)
            end
        end

        # @api private
        #
        # Applies modification information extracted from a transaction. This is
        # used by {Transaction#commit_transaction}
        def merge_transaction(transaction, merged_graphs, added, removed, updated)
            emit_relation_graph_transaction_application_hooks(added, prefix: 'adding')
            emit_relation_graph_transaction_application_hooks(removed, prefix: 'removing')
            emit_relation_graph_transaction_application_hooks(updated, prefix: 'updating')

            super

            precedence_graph = event_relation_graph_for(EventStructure::Precedence)
            precedence_edge_count = precedence_graph.num_edges
            emit_relation_graph_transaction_application_hooks(added, prefix: 'added')
            if precedence_edge_count != precedence_graph.num_edges
                execution_engine.event_ordering.clear
            end
            emit_relation_graph_transaction_application_hooks(removed, prefix: 'removed')
            if precedence_edge_count != precedence_graph.num_edges
                execution_engine.event_ordering.clear
            end
            emit_relation_graph_transaction_application_hooks(updated, prefix: 'updated')

            added.each do |graph, parent, child, info|
                log(:added_edge, parent, child, [graph.class], info)
            end
            removed.each do |graph, parent, child|
                execution_agent.needs_garbage_collection!
                log(:removed_edge, parent, child, [graph.class])
            end
            updated.each do |graph, parent, child, info|
                log(:updated_edge_info, parent, child, graph.class, info)
            end
        end

        def merging_plan(plan)
            plan.each_task_relation_graph do |graph|
                emit_relation_graph_merge_hooks(graph, prefix: 'adding')
            end
            plan.each_event_relation_graph do |graph|
                emit_relation_graph_merge_hooks(graph, prefix: 'adding')
            end
            super
        end

        def merged_plan(plan)
            if !plan.event_relation_graph_for(EventStructure::Precedence).empty?
                execution_engine.event_ordering.clear
            end

            if !plan.tasks.empty? || !plan.free_events.empty?
                execution_engine.needs_garbage_collection!
            end

            plan.each_task_relation_graph do |graph|
                emit_relation_graph_merge_hooks(graph, prefix: 'added')
            end
            plan.each_event_relation_graph do |graph|
                emit_relation_graph_merge_hooks(graph, prefix: 'added')
            end

            super

            log(:merged_plan, droby_id, plan)
        end

	# Hook called when a task is marked as garbage
        def garbage_task(task)
            task.each_event do |ev|
                for signalling_event in ev.parent_objects(EventStructure::Signal).to_a
                    signalling_event.remove_signal ev
                end
            end
            log(:garbage_task, droby_id, task)
            remove_task(task)
        end

	# Hook called when an event is marked as garbage
        def garbage_event(event)
            log(:garbage_event, droby_id, event)
            remove_free_event(event)
        end

        include Roby::ExceptionHandlingObject

        attr_reader :exception_handlers
        def each_exception_handler(&iterator); exception_handlers.each(&iterator) end
        def on_exception(matcher, &handler)
            check_arity(handler, 2)
            exception_handlers.unshift [matcher.to_execution_exception_matcher, handler]
        end

        def remove_task(object, timestamp = nil)
            if object.respond_to?(:running?) && object.running? && object.self_owned?
                raise ArgumentError, "attempting to remove a running task from an executable plan"
            end

            super
	    @force_gc.delete(object)
            @gc_quarantine.delete(object)
        end

        def clear
            super
            @force_gc.clear
            @gc_quarantine.clear
        end

	# Replace +task+ with a fresh copy of itself and start it.
        #
        # See #recreate for details about the new task.
	def respawn(task)
            new = recreate(task)
            execution_engine.once { new.start!(nil) }
	    new
	end

        def call_structure_check_handler(handler)
            super
        rescue Exception => e
            execution_engine.add_framework_error(e, 'structure checking')
        end
    end
end

