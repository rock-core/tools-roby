require 'roby/schedulers/basic'
module Roby
    module Schedulers
        # The temporal scheduler adds to the decisions made by the Basic
        # scheduler information given by the temporal constraint network.
        #
        # See the documentation of Roby::Schedulers for more information
        class Temporal < Basic
            # If true, the basic scheduler's constraints must be met for all
            # tasks. If false, they are applied only on tasks for which no
            # temporal constraints are set.
            attr_predicate :basic_constraints?, true

            def initialize(with_basic = true, with_children = true, plan = nil)
                super(with_children, plan)
                @basic_constraints = with_basic
            end

            # Starts all tasks that are eligible. See the class documentation
            # for an in-depth description
	    def can_schedule?(task)
                if !can_start?(task)
                    return false
                end

                start_event = task.start_event
                if start_event.has_scheduling_constraints?
                    if !start_event.can_be_scheduled?(Time.now)
                        return false
                    end
                    if basic_constraints?
                        super
                    else
                        return true
                    end
                else
                    super
		end
            end
        end
    end
end
