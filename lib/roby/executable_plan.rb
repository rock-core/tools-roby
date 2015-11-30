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

        def initialize
            super

            @execution_engine = nil

	    @force_gc    = Set.new
	    @gc_quarantine = Set.new
            @exception_handlers = Array.new
            on_exception LocalizedError do |plan, error|
                plan.default_localized_error_handling(error)
            end

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
                find_all { |t| mission?(t) && t != error.origin }.
                each do |m|
                    add_error(MissionFailedError.new(m, error.exception))
                end

            error.each_involved_task.
                find_all { |t| permanent?(t) && t != error.origin }.
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

        def added_event_relation(parent, child, relations)
            if relations.include?(Roby::EventStructure::Precedence)
                execution_engine.event_ordering.clear
            end
            super if defined? super
        end

        def removed_event_relation(parent, child, relations)
            if relations.include?(Roby::EventStructure::Precedence)
                execution_engine.event_ordering.clear
            end
            super if defined? super
        end

        def merged_plan(plan)
            if !plan.event_relation_graph_for(EventStructure::Precedence).empty?
                execution_engine.event_ordering.clear
            end
        end

	# Hook called when +task+ is marked as garbage. It will be garbage
	# collected as soon as possible
	def garbage(task_or_event)
	    # Remove all signals that go *to* the task
	    #
	    # While we want events which come from the task to be properly
	    # forwarded, the signals that go to the task are to be ignored
	    if task_or_event.respond_to?(:each_event) && task_or_event.self_owned?
		task_or_event.each_event do |ev|
		    for signalling_event in ev.parent_objects(EventStructure::Signal).to_a
			signalling_event.remove_signal ev
		    end
		end
	    end

	    super if defined? super

            remove_object(task_or_event)
	end

        include Roby::ExceptionHandlingObject

        attr_reader :exception_handlers
        def each_exception_handler(&iterator); exception_handlers.each(&iterator) end
        def on_exception(matcher, &handler)
            check_arity(handler, 2)
            exception_handlers.unshift [matcher.to_execution_exception_matcher, handler]
        end

        def remove_object(object, timestamp = nil)
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

