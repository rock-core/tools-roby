# frozen_string_literal: true

module Roby
    # A plan that can be used for execution
    #
    # While {Plan} maintains the plan data structure itself, this class provides
    # excution-related services such as exceptions and GC-related methods
    class ExecutablePlan < Plan
        extend Logger::Hierarchy
        extend Logger::Forward

        # The ExecutionEngine object which handles this plan. The role of this
        # object is to provide the event propagation, error propagation and
        # garbage collection mechanisms for the execution.
        #
        # @return [ExecutionEngine]
        attr_accessor :execution_engine

        # The ConnectionSpace object which handles this plan. The role of this
        # object is to sharing with other Roby plan managers
        attr_accessor :connection_space

        # @deprecated use {#execution_engine} instead
        def engine
            Roby.warn_deprecated(
                "Plan#engine is deprecated, use #execution_engine instead"
            )
            execution_engine
        end

        # The DecisionControl object which is associated with this plan. This
        # object's role is to handle the conflicts that can occur during event
        # propagation.
        def control
            execution_engine.control
        end

        # A set of tasks which are useful (and as such would not been garbage
        # collected), but we want to GC anyway
        #
        # @return [Set<Roby::Task>]
        attr_reader :force_gc

        # The list of plan-wide exception handlers
        #
        # @return [Array<(#===, #call)>]
        attr_reader :exception_handlers

        def initialize(event_logger: DRoby::NullEventLogger.new)
            super(graph_observer: self, event_logger: event_logger)

            @execution_engine = ExecutionEngine.new(self)
            @quarantined_tasks = Set.new
            @force_gc = Set.new
            @exception_handlers = []
            on_exception LocalizedError do |plan, error|
                plan.default_localized_error_handling(error)
            end
        end

        # Set of running tasks that are in quarantine
        #
        # @return [Set<Task>]
        attr_reader :quarantined_tasks

        # (see Task#quarantined!)
        def quarantine_task(task, reason: nil)
            task.quarantined!(reason: reason)
        end

        # @api private
        #
        # Helper to {#quaratine_task}
        def register_quarantined_task(task)
            log(:quarantined_task, droby_id, task)
            @quarantined_tasks << task
        end

        # Check that this is an executable plan
        #
        # This always returns true for {ExecutablePlan}
        def executable?
            true
        end

        def refresh_relations
            super
            execution_engine.refresh_relations
        end

        def event_logger=(logger)
            super
            log :register_executable_plan, droby_id
        end

        # @api private
        #
        # Default toplevel error handling for {LocalizedError}
        #
        # It activates fault handlers, and adds {MissionFailedError} /
        # {PermanentTaskError}
        def default_localized_error_handling(error)
            matching_handlers = []
            active_fault_response_tables.each do |table|
                table.find_all_matching_handlers(error).each do |handler|
                    matching_handlers << [table, handler]
                end
            end
            handlers = matching_handlers.sort_by { |_, handler| handler.priority }

            until handlers.empty?
                table, handler = handlers.shift
                next unless handler

                begin
                    handler.activate(error, table.arguments)
                    return
                rescue Exception => e
                    Robot.warn "ignored exception handler #{handler} " \
                               "because of exception"
                    Roby.log_exception_with_backtrace(e, Robot, :warn)
                end
            end

            pass_exception
        end

        def generate_induced_errors(error_phase_results)
            error_phase_results.each_fatal_error do |execution_exception, tasks|
                # MissionFailedError and PermanentTaskError are not propagated,
                # so tasks == [origin] and we should not re-add an error
                if execution_exception.exception.kind_of?(MissionFailedError) ||
                   execution_exception.exception.kind_of?(PermanentTaskError)
                    next
                end

                tasks.each do |t|
                    if mission_task?(t)
                        add_error(
                            MissionFailedError.new(t, execution_exception.exception),
                            propagate_through: []
                        )
                    elsif permanent_task?(t)
                        add_error(
                            PermanentTaskError.new(t, execution_exception.exception),
                            propagate_through: []
                        )
                    end
                end
            end
        end

        def check_structure
            super.merge(check_quarantined_tasks_in_use)
        end

        # @api private
        #
        # Look for quarantined tasks that are still in use
        def check_quarantined_tasks_in_use
            @quarantined_tasks.each_with_object({}) do |task, result|
                if quarantined_task_in_use?(task)
                    error = QuarantinedTaskError.new(task)
                    result[error.to_execution_exception] = nil
                end
            end
        end

        # Check whether the given quarantined task is in use
        #
        # It is used to determine whether a {QuarantinedTaskError} should be
        # generated
        #
        # @param [Task] task a quarantined task
        def quarantined_task_in_use?(task)
            return true if mission_task?(task) || permanent_task?(task)

            default_useful_task_graphs.each do |g|
                g.each_in_neighbour(task) do |parent_t|
                    return true unless parent_t.finished? || parent_t.quarantined?
                end
            end

            false
        end

        # Calls the given block in the execution thread of this plan's engine.
        # If there is no engine attached to this plan, yields immediately
        #
        # See ExecutionEngine#execute
        def execute(&block)
            execution_engine.execute(&block)
        end

        # @api private
        #
        # Hook called when a task is finalized
        def finalized_task(task)
            execution_engine.finalized_task(task)
            super
        end

        # @api private
        #
        # Hook called when an event is finalized
        def finalized_event(event)
            execution_engine.finalized_event(event)
            super
        end

        # @api private
        #
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
            if !parent.read_write? || !child.read_write?
                raise OwnershipError,
                      "cannot remove a relation between two objects we don't own"
            elsif parent.garbage?
                raise ReusingGarbage,
                      "attempting to reuse #{parent} which is marked as garbage"
            elsif child.garbage?
                raise ReusingGarbage,
                      "attempting to reuse #{child} which is marked as garbage"
            end

            last_dag = relations.find_all(&:dag?).last
            if last_dag && child.relation_graph_for(last_dag).reachable?(child, parent)
                raise Relations::CycleFoundError,
                      "adding an edge from #{parent} to #{child} would create " \
                      "a cycle in #{last_dag}"
            end

            relations.each do |rel|
                if (name = rel.child_name)
                    parent.send("adding_#{name}", child, info)
                    child.send("adding_#{name}_parent", parent, info)
                end
            end

            for trsc in transactions
                next unless trsc.proxying?
                next unless (parent_proxy = trsc[parent, create: false])
                next unless (child_proxy = trsc[child, create: false])

                trsc.adding_plan_relation(parent_proxy, child_proxy, relations, info)
            end
        end

        # @api private
        #
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

                if (name = rel.child_name)
                    parent.send("added_#{name}", child, info)
                    child.send("added_#{name}_parent", parent, info)
                end
            end

            log(:added_edge, parent, child, relations, info)
        end

        # @api private
        #
        # Hook called to announce that the edge information of an existing edge
        # will be updated
        #
        # @param parent the edge parent object
        # @param child the edge child object
        # @param [Class<Relations::Graph>] relation the relation graph ID
        # @param [Object] info the new edge info
        def updating_edge_info(parent, child, relation, info)
            emit_relation_change_hook(parent, child, relation, info, prefix: "updating")
        end

        # @api private
        #
        # Hook called when the edge information of an existing edge has been
        # updated
        #
        # @param parent the edge parent object
        # @param child the edge child object
        # @param [Class<Relations::Graph>] relation the relation graph ID
        # @param [Object] info the new edge info
        def updated_edge_info(parent, child, relation, info)
            emit_relation_change_hook(parent, child, relation, info, prefix: "updated")
            log(:updated_edge_info, parent, child, relation, info)
        end

        # @api private
        #
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
                raise OwnershipError,
                      "cannot remove a relation between two objects we don't own"
            end

            relations.each do |rel|
                if (name = rel.child_name)
                    parent.send("removing_#{name}", child)
                    child.send("removing_#{name}_parent", parent)
                end
            end

            for trsc in transactions
                next unless trsc.proxying?
                next unless (parent_proxy = trsc[parent, create: false])
                next unless (child_proxy = trsc[child, create: false])

                trsc.removing_plan_relation(parent_proxy, child_proxy, relations)
            end
        end

        # @api private
        #
        # Hook called after an edge has been removed from this plan
        #
        # @param [Object] parent the child object
        # @param [Object] child the child object
        # @param [Array<Class<Relations::Graph>>] relations the graphs in which an edge
        #   has been removed
        def removed_edge(parent, child, relations)
            relations.each do |rel|
                if (name = rel.child_name)
                    parent.send("removed_#{name}", child)
                    child.send("removed_#{name}_parent", parent)
                end
            end

            log(:removed_edge, parent, child, relations)
        end

        # @api private
        #
        # Helper for {#updating_edge_info} and {#updated_edge_info}
        def emit_relation_change_hook(parent, child, rel, *args, prefix: nil)
            if (name = rel.child_name)
                parent.send("#{prefix}_#{name}", child, *args)
                child.send("#{prefix}_#{name}_parent", parent, *args)
            end
        end

        # @api private
        #
        # Calls the added_* hook methods for all edges in a relation graph
        #
        # It is a helper for {#merged_plan}
        def emit_relation_graph_merge_hooks(graph, prefix: nil)
            rel = graph.class
            if (name = rel.child_name)
                added_child_hook  = "#{prefix}_#{name}"
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
            hooks = {}
            list.each do |graph, parent, child, *args|
                unless hooks.has_key?(graph)
                    rel = graph.class
                    if (name = rel.child_name)
                        parent_hook = "#{prefix}_#{name}"
                        child_hook  = "#{parent_hook}_parent"
                        hooks[graph] = [parent_hook, child_hook]
                    else
                        hooks[graph] = nil
                    end
                end

                parent_hook, child_hook = hooks[graph]
                next unless child_hook

                parent.send(parent_hook, child, *args)
                child.send(child_hook, parent, *args)
            end
        end

        # @api private
        #
        # Applies modification information extracted from a transaction. This is
        # used by {Transaction#commit_transaction}
        def merge_transaction(transaction, merged_graphs, added, removed, updated)
            added.each do |_, parent, child, _|
                if parent.garbage?
                    raise ReusingGarbage,
                          "attempting to reuse #{parent} which is marked as garbage"
                elsif child.garbage?
                    raise ReusingGarbage,
                          "attempting to reuse #{child} which is marked as garbage"
                end
            end

            emit_relation_graph_transaction_application_hooks(added, prefix: "adding")
            emit_relation_graph_transaction_application_hooks(removed, prefix: "removing")
            emit_relation_graph_transaction_application_hooks(updated, prefix: "updating")

            super

            precedence_graph = event_relation_graph_for(EventStructure::Precedence)
            precedence_edge_count = precedence_graph.num_edges
            emit_relation_graph_transaction_application_hooks(added, prefix: "added")
            if precedence_edge_count != precedence_graph.num_edges
                execution_engine.event_ordering.clear
            end
            emit_relation_graph_transaction_application_hooks(removed, prefix: "removed")
            if precedence_edge_count != precedence_graph.num_edges
                execution_engine.event_ordering.clear
            end
            emit_relation_graph_transaction_application_hooks(updated, prefix: "updated")

            added.each do |graph, parent, child, info|
                log(:added_edge, parent, child, [graph.class], info)
            end
            removed.each do |graph, parent, child|
                log(:removed_edge, parent, child, [graph.class])
            end
            updated.each do |graph, parent, child, info|
                log(:updated_edge_info, parent, child, graph.class, info)
            end
        end

        # @api private
        #
        # Emits the adding_* hooks when a plan gets merged in self
        def merging_plan(plan)
            plan.each_task_relation_graph do |graph|
                emit_relation_graph_merge_hooks(graph, prefix: "adding")
            end
            plan.each_event_relation_graph do |graph|
                emit_relation_graph_merge_hooks(graph, prefix: "adding")
            end
            super
        end

        # @api private
        #
        # Emits the added_* hooks when a plan gets merged in self
        def merged_plan(plan)
            unless plan.event_relation_graph_for(EventStructure::Precedence).empty?
                execution_engine.event_ordering.clear
            end

            plan.each_task_relation_graph do |graph|
                emit_relation_graph_merge_hooks(graph, prefix: "added")
            end
            plan.each_event_relation_graph do |graph|
                emit_relation_graph_merge_hooks(graph, prefix: "added")
            end

            super

            log(:merged_plan, droby_id, plan)
        end

        # @api private
        #
        # Called to handle a task that should be garbage-collected
        #
        # What actually happens to the task is controlled by
        # {PlanObject#can_finalize?}.
        #
        # If the task can be finalized, it is removed from the plan, after
        # having triggered all relevant log events/hooks.
        #
        # Otherwise, it is isolated from the rest of the plan. Its relations and
        # the relations of its events are cleared and the task is left in the
        # plan. In the latter case, the task is marked as non-reusable.
        #
        # Always check {Task#reusable?} before using a task present in an
        # {ExecutablePlan} in a new structure.
        #
        # @param [Task] task the task that is being garbage-collected
        # @return [Boolean] true if the plan got modified, and false otherwise.
        #   In practice, it will return false only if the task cannot be
        #   finalized *and* has external relations.
        def garbage_task(task)
            log(:garbage_task, droby_id, task, task.can_finalize?)

            if task.can_finalize?
                remove_task(task)
                true
            else
                task.garbage!
                task.clear_relations(remove_internal: false, remove_strong: false)
            end
        end

        # Called to handle a free event that should be garbage-collected
        #
        # What actually happens to the event is controlled by
        # {PlanObject#can_finalize?}. If the event can be finalized, it is (i.e.
        # removed from the plan, after having triggered all relevant log
        # events/hooks). Otherwise, its relations are cleared and the task is
        # left in the plan
        #
        # @return [Boolean] true if the plan got modified, and false otherwise.
        #   In practice, it will return false only for events that had no
        #   relations and that cannot be finalized.
        def garbage_event(event)
            log(:garbage_event, droby_id, event)
            if event.can_finalize?
                remove_free_event(event)
                true
            else
                event.clear_relations(remove_strong: false)
            end
        end

        include Roby::ExceptionHandlingObject

        # Iterate over the plan-wide exception handlers
        #
        # @yieldparam [#===] matcher an object that allows to match an
        #   {ExecutionException}
        # @yieldparam [#call] handler the exception handler, which will be
        #   called with the plan and the {ExecutionException} object as argument
        def each_exception_handler(&block)
            exception_handlers.each(&block)
        end

        # Register a new exception handler
        #
        # @param [#===,#to_execution_exception_matcher] matcher
        #   an object that matches exceptions for which the handler should be
        #   called. Exception classes can be used directly. If more advanced
        #   matching is needed, use .match to convert an exception class into
        #   {Queries::LocalizedErrorMatcher} or one of its subclasses.
        #
        # @yieldparam [ExecutablePlan] plan the plan in which the exception
        #   happened
        # @yieldparam [ExecutionException] exception the exception that is being handled
        def on_exception(matcher, &handler)
            check_arity(handler, 2)
            exception_handlers.unshift [matcher.to_execution_exception_matcher, handler]
            Roby.disposable do
                exception_handlers.delete_if { |_, h| h == handler }
            end
        end

        # Actually remove a task from the plan
        def remove_task(object, timestamp = nil)
            if object.respond_to?(:running?) && object.running? && object.self_owned?
                raise ArgumentError,
                      "attempting to remove #{object}, which is a running task, " \
                      "from an executable plan"
            end

            super

            @force_gc.delete(object)
            @quarantined_tasks.delete(object)
        end

        # Clear the plan
        def clear
            super
            @force_gc.clear
            @quarantined_tasks.clear
        end

        # Replace +task+ with a fresh copy of itself and start it.
        #
        # See #recreate for details about the new task.
        def respawn(task)
            new = recreate(task)
            execution_engine.once { new.start!(nil) }
            new
        end

        # @api private
        #
        # Called by {ExecutionEngine} to verify the plan's internal structure
        def call_structure_check_handler(handler)
            super
        rescue Exception => e
            execution_engine.add_framework_error(e, "structure checking")
        end
    end
end
