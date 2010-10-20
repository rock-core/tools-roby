module Roby
    module Schedulers
        # The temporal scheduler adds to the decisions made by the Basic
        # scheduler information given by the temporal constraint network.
        #
        # See the documentation of Roby::Schedulers for more information
        #
        # More specifically, this scheduler starts the tasks for which:
        #  * the task is pending, executable and owned by the local plan manager
        #  * the task's start event is root in the signal and forward relations
        #  * the task is root in the dependency relationship, or all its parents
        #    are started
        #  * the temporal constraints of the task's start event are met
        class Temporal
            # The plan on which the scheduler applies
            attr_reader :plan
            # The Roby::Query which is used to get the set of tasks that might
            # be startable
	    attr_reader :query

            # Create a new Basic schedulers that work on the given plan, and
            # with the provided +include_children+ option.
            #
            # See Basic for a description of the +include_children+ option.
            #
            # If +plan+ is set to nil, the scheduler will use Roby.plan
	    def initialize(plan = nil)
                @plan = plan || Roby.plan
		@query = self.plan.find_tasks.
		    executable.
		    pending.
		    self_owned
	    end

            # Starts all tasks that are eligible. See the class documentation
            # for an in-depth description
	    def initial_events
		for task in query.reset
                    start_event = task.start_event
                    next if !start_event.controlable?
                    next if !start_event.root?(EventStructure::Forwarding)
                    next if !start_event.root?(EventStructure::Signal)

                    schedulable = task.root?(TaskStructure::ErrorHandling)
                    next if !schedulable

                    if start_event.is_temporally_constrained?
                        if start_event.meets_temporal_constraints?(Time.now)
                            start_event.call
                        end
                    else
                        root_task =
                            if task.root?(TaskStructure::Dependency)
                                true
                            else
                                planned_tasks = task.planned_tasks
                                !planned_tasks.empty? &&
                                    planned_tasks.all? { |t| !t.executable? }
                            end

                        if root_task || task.parents.any? { |t| t.running? }
                            start_event.call
                        end
                    end
		end
            end
        end
    end
end
