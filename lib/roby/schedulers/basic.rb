require 'roby/schedulers/reporting'

module Roby
    # The namespace in which Roby's default schedulers are defined
    #
    # In Roby, the scheduler is an object that decides which tasks to start at
    # any given time. There can be only one scheduler, which is set at
    # initialization time with
    #
    #   Roby.scheduler = <scheduler object>.
    #
    # For instance
    #
    #   Roby.scheduler = Roby::Schedulers::Basic.new
    #
    # Then, the scheduler's #initial_events method is called at the
    # beginning of each execution cycle. This method is supposed to call
    # whatever event is reasonable to call with respect to the system's
    # state (i.e. execution situation).
    module Schedulers
        extend Logger::Hierarchy
        extend Logger::Forward

        # The basic schedulers uses the Roby's "core" plan model to decide which
        # tasks can be started.
        #
        # See the documentation of Roby::Schedulers for more information
        #
        # The basic scheduler starts the tasks for which:
        #  * the task is pending, executable and owned by the local robot
        #  * the start event is root in all event relations (i.e. there is
        #    neither signals and forwards pointing to it).
        #  * it is root in the dependency relationship
        #  * if the +include_children+ option of Basic.new is set to true, it
        #    may be non-root in the dependency relation, in which case it is
        #    started if and only if it has at least one parent that is running
        #    (i.e. children are started after their parents).
        #
	class Basic < Reporting
            # The plan on which the scheduler applies
            attr_reader :plan
            # The Roby::Query which is used to get the set of tasks that might
            # be startable
	    attr_reader :query
            # If true, the scheduler will start tasks which are non-root in the
            # dependency relation, if they have parents that are already
            # running. 
            attr_reader :include_children

            # Create a new Basic schedulers that work on the given plan, and
            # with the provided +include_children+ option.
            #
            # See Basic for a description of the +include_children+ option.
            #
            # If +plan+ is set to nil, the scheduler will use Roby.plan
	    def initialize(include_children = false, plan = nil)
                super()

                @plan = plan || Roby.plan
                @include_children = include_children
		@query = self.plan.find_tasks.
		    executable.
		    pending.
		    self_owned

                @can_schedule_cache = Hash.new
                @enabled = true
	    end

            attr_predicate :enabled?, true

            def can_start?(task)
                start_event = task.start_event
                if !start_event.controlable?
                    report_holdoff "start event not controlable", task
                    return false
                end

                if !start_event.root?(EventStructure::CausalLink)
                    report_holdoff "start event not root in the causal link relation", task
                    return false
                end

                task.each_relation do |r|
                    if r.respond_to?(:scheduling?) && !r.scheduling? && !task.root?(r)
                        report_holdoff "not root in %2, which forbids scheduling", task, r
                        return false 
                    end
                end
                true
            end

            def can_schedule?(task, time = Time.now, stack = [])
                if !can_start?(task)
                    report_holdoff "cannot be started", task
                    return false
                end

                root_task =
                    if task.root?(TaskStructure::Dependency)
                        true
                    else
                        planned_tasks = task.planned_tasks
                        !planned_tasks.empty? &&
                            planned_tasks.all? { |t| !t.executable? }
                    end

                if root_task
                    true
                elsif include_children && task.parents.any? { |t| t.running? }
                    true
                else
                    report_holdoff "not root, and has no running parent", task
                    false
                end
            end

            # Starts all tasks that are eligible. See the documentation of the
            # Basic class for an in-depth description
	    def initial_events
                @can_schedule_cache.clear
                time = Time.now

                not_executable = self.plan.find_tasks.
                    not_executable.
                    pending.
                    self_owned

                not_executable.each do |task|
                    # Try to figure out why ...
                    if task.execution_agent && !task.execution_agent.ready?
                        report_pending_non_executable_task("execution agent %2 not ready", task, task.execution_agent)
                    elsif task.partially_instanciated?
                        report_pending_non_executable_task("partially instanciated", task)
                    else
                        report_pending_non_executable_task("not executable", task)
                    end
                end

                scheduled_tasks = []
		for task in query.reset
                    result =
                        if @can_schedule_cache.include?(task)
                            @can_schedule_cache[task]
                        else @can_schedule_cache[task] = can_schedule?(task, time, [])
                        end

                    if result
                        task.start!
                        report_trigger task.start_event
                        scheduled_tasks << task
                    end
		end
                scheduled_tasks
	    end
	end
    end
end

