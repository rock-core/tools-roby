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
                    report_holdoff "cannot be started", task
                    return false
                end

                start_event = task.start_event

                event_filter = lambda do |ev|
                    if ev.respond_to?(:task)
                        ev.task != task &&
                            !stack.include?(ev.task) &&
                            !Roby::EventStructure::SchedulingConstraints.related_tasks?(ev.task, task)
                    else true
                    end
                end

                meets_constraints = start_event.meets_temporal_constraints?(time, &event_filter)
                if !meets_constraints
                    if failed_temporal = start_event.find_failed_temporal_constraint(time, &event_filter)
                        report_holdoff "temporal constraints not met (%2: %3)", task, failed_temporal[0], failed_temporal[1]
                    end
                    if failed_occurence = start_event.find_failed_occurence_constraint(true, &event_filter)
                        report_holdoff "occurence constraints not met (%2)", task, failed_occurence
                    end
                    return false
                end

                start_event.each_backward_scheduling_constraint do |parent|
                    begin
                        stack.push task
                        if !can_schedule?(parent.task, time, stack)
                            report_holdoff "%2 cannot be scheduled and %1.schedule_as(%2)", task, parent
                            return false
                        end
                    ensure
                        stack.pop
                    end
                end

                if basic_constraints?
                    if super
                        return true
                    else
                        # Special case: check in Dependency if there are some
                        # parents for which a forward constraint from +self+ to
                        # +parent.start_event+ exists. If it is the case, start
                        # the task
                        task.each_parent_task do |parent|
                            parent.start_event.each_backward_temporal_constraint do |constraint|
                                if constraint.respond_to?(:task) && constraint.task == task
                                    Schedulers.debug { "Temporal: #{task} has no running parent, but a constraint from #{constraint} to #{parent}.start exists. Scheduling." }
                                    return true
                                end
                            end
                        end
                        return false
                    end
                else
                    return true
                end
            end
        end
    end
end

