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

            def can_schedule?(task, time = Time.now, stack = [])
                if task.running?
                    return true
                elsif !can_start?(task)
                    Schedulers.debug { "Temporal: won't schedule #{task} as it cannot be started" }
                    return false
                end

                start_event = task.start_event

                meets_constraints = start_event.meets_temporal_constraints?(time) do |ev|
                    if ev.respond_to?(:task)
                        ev.task != task &&
                            !stack.include?(ev.task) &&
                            !Roby::EventStructure::SchedulingConstraints.related_tasks?(ev.task, task)
                    end
                end

                if !meets_constraints
                    Schedulers.debug { "Temporal: won't schedule #{task} as its temporal constraints are not met" }
                    return false
                end

                start_event.each_backward_scheduling_constraint do |parent|
                    begin
                        stack.push task
                        if !can_schedule?(parent.task, time, stack)
                            Schedulers.debug { "Temporal: won't schedule #{task} as #{parent} cannot be scheduled and #{task}.schedule_as(#{parent})" }
                            return false
                        end
                    ensure
                        stack.pop
                    end
                end

                if basic_constraints?
                    super
                else
                    return true
                end
            end
        end
    end
end

