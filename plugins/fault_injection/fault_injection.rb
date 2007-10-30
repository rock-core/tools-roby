module Roby
    def FaultInjection.apply(fault_models)
	injected_faults = Array.new

	for model, faults in fault_models
	    for ev, p in faults
		p = if p.respond_to?(:call)
			p.call
		    elsif p.kind_of?(Numeric)
			p
		    else
			Robot.warn "invalid fault model #{p} for #{model}/#{ev}. Ignored"
		    end

		Roby.plan.find_tasks(model).
		    running.not_finishing.
		    interruptible.each do |task|
			value = rand
			if value <= p
			    Robot.info "injecting fault #{ev} on #{task} (#{value} <= #{p})"
			    injected_faults << [task, ev, task.inject_fault(ev)]
			end
		    end
	    end
	end

	injected_faults
    end

    class Task
	# Makes the plan behave as if this task had failed by emitting the
	# event +event+ with context +context+.
	#
	# The task must be running and interruptible, and +event+ must be
	# terminal. The default implementation creates a duplicate of this task
	# by using #dup and forwards the +stop+ event of the old task to
	# +event+ on the new one.
	#
	# It returns a new task which replaced this one in the plan. This is
	# the task on which +event+ will actually be emitted.
	def inject_fault(event, context = nil)
	    if !running?
		raise ArgumentError, "this task is not running"
	    elsif finishing?
		raise ArgumentError, "this task is being stopped"
	    elsif !interruptible?
		raise ArgumentError, "fault injection works only on interruptible tasks"
	    elsif !event(event).terminal?
		raise ArgumentError, "the injected fault must be a terminal event"
	    end

	    new_task = dup
	    old_task = self

	    plan.replace_task(old_task, new_task)
	    old_task.event(:stop).filter(context).forward new_task.event(event)

	    new_task
	end
    end
end

