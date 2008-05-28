module Roby
    class Task
	# Returns for how many seconds this task is running.  Returns nil if
	# the task is not running.
	def lifetime
	    if running?
		Time.now - history.first.time
	    end
	end
    end

    module FaultInjection
	extend Logger::Hierarchy
	extend Logger::Forward
	
	# This fault model is based on a constant fault rate, defined upon the
	# mean-time-to-failure of the task.
	#
	# In this model, the probability of having a fault for task t at any
	# given instant is
	#
	#   p(fault) = max * (1.0 - exp(- task.lifetime / mttf))
	#
	class Rate
	    attr_reader :mttf, :max
	    def initialize(mttf, max = 1.0)
		@mttf, @max = mttf, max
	    end

	    def fault?(task)
		f = max * (1.0 - Math.exp(- task.lifetime / mttf))
		rand <= f
	    end
	end

	# Apply the given fault models to the main Roby plan
	def self.apply(fault_models)
	    injected_faults = Array.new

	    for model, faults in fault_models
		for ev, p in faults
		    Roby.plan.find_tasks(model).
			running.not_finishing.
			interruptible.each do |task|
			    if p.fault?(task)
				FaultInjection.info "injecting fault #{ev} on #{task}"
				injected_faults << [task, ev, task.inject_fault(ev)]
			    end
			end
		end
	    end

	    injected_faults
	end
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

