module Roby
    # This class unrolls a loop in the plan. It maintains +lookahead+ patterns
    # developped at all times by calling an external planner, and manages them.
    # This documentation will start by describing the general behaviour of this
    # task, and then we will detail different specific modes of operation.
    #
    # == Behaviour description
    # The task unrolls the loop by generating /patterns/, which are a
    # combination of a task representing the operation to be done during one
    # pass of the loop, and a planning task which will generate the subplan for
    # this operation. These patterns are developped as children of either the
    # PlanningLoop task itself, or its planned_task if there is one.
    #
    # During the execution of this suite of patterns, the following constraints
    # are always met:
    #
    # * the planning task of a pattern is started after the one of the previous
    #   pattern has finished.
    # * a pattern is started after the previous one has finished.
    #
    # The #start! command do not starts the loop per-se. It only makes the
    # first +lookahead+ patterns to be developped. You have to call
    # #loop_start! once to start the generated patterns themselves.
    #
    # == Periodic and nonperiodic loops
    # On the one hand, if the +:period+ option of #initialize is non-nil, it is
    # expected to be a floating-point value representing a time in seconds. In
    # that case, the loop is *periodic* and each pattern in the loop is started
    # at the given periodic rate, triggered by the #periodic_trigger event.
    # Note that the 'zero-period' case is a special situation where the loop
    # runs as fast as possible. 
    #
    # On the other hand, if +:period+ is nil, the loop is nonperiodic, and each
    # pattern must be explicitely started by calling #loop_start!.  Finally,
    # #loop_start! can also be called to bypass the period value (i.e.  to
    # start a pattern earlier than expected). Repetitive calls to #loop_start!
    # will make the loop develop and start at most one pattern.
    #
    # == Zero lookahead
    # When the loop lookahead is nonzero, patterns are planend ahead-of-time: they
    # are planned as soon as possible. In some cases, it is non desirable, for instance
    # because some information is available only at a later time.
    #
    # For these situations, one can use a zero lookahead. In that case, the
    # patterns are not pre-planned, but instead the planning task is started
    # only when the pattern itself should have been started: either when the
    # period timeouts, or when #loop_start! is explicitely called.
    #
    # TODO: make figures.
    #
    class PlanningLoop < Roby::Task
	terminates

	# An array of [planning_task, user_command]. The *last* element is the
	# *first* arrived
	attr_reader :patterns

	# For periodic updates. If false, the next loop is started when the
	# 'loop_start' command is called
	argument :period
	# How many loops should we have unrolled at all times
	argument :lookahead

	# The task model we should produce
	argument :planned_model

	# The planner model we should use
	argument :planner_model

        # The planner method name. This is not a mandatory argument as
        # otherwise we would break logging and distributed Roby: this attribute
        # can hold a MethodDefinition object that cannot be shared.
        #
        # Anyway, the only meaningful argument in distributed context is the
        # method name itself. Event method_options could be removed in the
        # future.
	def planning_method
            arguments[:planning_method]
        end
	# The planner method options
	argument :method_options

        # The method name. This can be nil a FreeMethod is used for planning
        argument :method_name

	# Filters the options in +options+, splitting between the options that
	# are specific to the planning task and those that are to be forwarded
	# to the planner itself
	def self.filter_options(options)
	    task_arguments, planning_options = Kernel.filter_options options, 
		:period => nil,
		:lookahead => 1,
		:planner_model => nil,
                :planning_method => nil,
		:planned_model => Roby::Task,
		:method_name => nil,
		:method_options => {},
		:planning_owners => nil

            task_arguments = PlanningTask.validate_planning_options(task_arguments)

	    if task_arguments[:lookahead] < 0
		raise ArgumentError, "lookahead must be positive"
	    end
	    task_arguments[:period] ||= nil
	    [task_arguments, planning_options]
	end

        # If this loop is periodic of nonzero period, the state event which
        # represents that period.
        attr_reader :periodic_trigger

	def initialize(options)
	    task_arguments, planning_options = PlanningLoop.filter_options(options)
	    task_arguments[:method_options].merge!(planning_options)
	    super(task_arguments)

            if period && period > 0
                @periodic_trigger = State.on_delta :t => period
                periodic_trigger.disable
                periodic_trigger.on event(:loop_start)
            end
            
	    @patterns = []
            @pattern_id = 0
	end

	# The task on which the children are added
	def main_task; planned_task || self end
	
	def planned_task # :nodoc:
	    planned_tasks.find { true } 
	end

	# The PlanningTask object for the last pattern
	def last_planning_task
	    if pattern = patterns.first
		pattern.first
	    end
	end

	# Appends a new unplanned pattern after all the patterns already developped
	#
	# +context+ is forwarded to the planned task
	def append_pattern(*context)
	    # Create the new pattern
	    task_arguments = arguments.slice(:planner_model, :planned_model, :planning_method)
	    task_arguments[:method_options] = method_options.dup
	    task_arguments[:method_options][:pattern_id] = @pattern_id
	    @pattern_id += 1

	    planning = PlanningTask.new(task_arguments)
	    planned  = planning.planned_task
	    planned.forward(:start,   self, :loop_start)
	    planned.forward(:success, self, :loop_success)
	    planned.forward(:stop,    self, :loop_end)
	    main_task.realized_by planned
	    
	    # Schedule it. We start the new pattern when these three conditions are met:
	    # * it has been planned (planning has finished)
	    # * the previous one (if any) has finished
            # * the period (if any) has expired or an external event required
            #   the explicit start of the pattern (call done to user_command,
            #   for instance through a call to #loop_start!)
            #
            # The +precondition+ event represents a situation where the new pattern
            # *can* be started, while +command+ is the situation asking for the
            # pattern to start.
	    precondition = planning.event(:success)
	    user_command = EventGenerator.new(true)
            command      = user_command

	    if last_planning = last_planning_task
		last_planned = last_planning.planned_task

                if !last_planned.finished?
		    precondition &= last_planned.event(:stop)
		end

                if period && !periodic_trigger
                    command |= planned.event(:success)
                end

		if last_planning.finished?
		    planning.start!(*context) 
		else
		    last_planning.event(:success).filter(*context).on(planning.event(:start))
		end
	    end
            command &= precondition

	    patterns.unshift([planning, user_command])
	    command.on(planned.event(:start))
	    planning
	end

        # Remove all pending patterns and starts unrolling as much new patterns
        # as lookahead requires. Kills the currently running pattern (if there
        # is one).
	event :reinit do |context|
            did_reinit = []

            # Remove all realized_by relations and all pending patterns from
            # the pattern set.
            for pattern in patterns
                old_planning, ev = pattern
                old_task = old_planning.planned_task
                main_task.remove_child old_task

                if old_task && old_task.running?
                    did_reinit << old_task.event(:stop)
                elsif old_planning.running?
                    did_reinit << old_planning.event(:stop)
                end
            end
            patterns.clear

            if did_reinit.empty?
                emit :reinit
            else
                did_reinit.
                    map { |ev| ev.when_unreachable }.
                    inject { |a, b| a & b }.
                    forward event(:reinit)
            end
        end
        on :reinit do |ev|
	    @pattern_id = 0
	    if lookahead > 0
		first_planning = nil
		while patterns.size < lookahead
		    new_planning = append_pattern
		    first_planning ||= new_planning
		end
		first_planning.start!
	    end
            loop_start!
        end

        # Generates the first +lookahead+ patterns and start planning. The
        # patterns themselves are started when +loop_start+ is called the first
        # time.
	event :start do
	    if lookahead > 0
		first_planning = nil
		while patterns.size < lookahead
		    new_planning = append_pattern
		    first_planning ||= new_planning
		end
		on(:start, first_planning)
	    end

	    emit :start
	end
        

        # The first time, start executing the patterns. During the loop
        # execution, force starting the next pending pattern, bypassing the
        # period if there is one. In case of zero-lookahead loops, the next
        # pattern will be planned before it is executed.
	event :loop_start do |context|
            # Start the periodic trigger if there is one
            if periodic_trigger && periodic_trigger.disabled?
                periodic_trigger.enable
            end

            # Find the first non-running pattern and start it. In case of
            # zero-lookahead, if no task is already pending, we should add one
            # and start it explicitely
	    if new_pattern = patterns.reverse.find { |task, ev| task.planned_task.pending? }
                t, ev = new_pattern
                ev.call(*context)
                command = ev.enum_child_objects(EventStructure::Signal).find { true }
            elsif lookahead == 0
		start_planning = !last_planning_task
		planning = append_pattern(*context)
		if start_planning
		    planning.start!(*context)
		end
                _, ev = patterns[0]
                ev.call(*context)
	    end
	end

	on :loop_start do |event| 
	    return unless self_owned?
            if event.task.lookahead != 0
                append_pattern 
            end

	    main_task.remove_finished_children
	end

	event :loop_success

	event :loop_end
	on :loop_end do |event|
	    return unless self_owned?
	    patterns.pop
	end

	# For ordering during event propagation
	causal_link :loop_start   => :loop_end
	causal_link :loop_success => :loop_end
    end
end

