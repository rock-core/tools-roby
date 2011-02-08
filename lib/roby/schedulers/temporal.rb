require 'roby/schedulers/basic'
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
        class Temporal < Basic
            # Starts all tasks that are eligible. See the class documentation
            # for an in-depth description
	    def can_schedule?(task)
                if !can_start?(task)
                    return false
                end

                start_event = task.start_event
                if start_event.has_scheduling_constraints?
                    start_event.can_be_scheduled?(Time.now)
                else
                    super
		end
            end
        end
    end
end
