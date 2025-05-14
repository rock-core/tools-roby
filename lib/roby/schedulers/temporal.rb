# frozen_string_literal: true

require "roby/schedulers/basic"
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

            # The proper graph object that contains the scheduling constraints
            attr_reader :scheduling_constraints_graph

            def initialize(with_basic = true, with_children = true, plan = nil)
                super(with_children, plan)
                @basic_constraints = with_basic
                @scheduling_constraints_graph = self.plan
                    .event_relation_graph_for(EventStructure::SchedulingConstraints)
            end

            def can_schedule?(task, time = Time.now, stack = [])
                if task.running?
                    return true
                elsif !can_start?(task)
                    report_holdoff "cannot be started", task
                    return false
                end

                return false unless verify_temporal_constraints(task, time, stack)
                return false unless verify_schedule_as_constraints(task, time, stack)
                return true unless basic_constraints?

                root_task = basic_scheduling_root_task?(task)
                if root_task
                    true
                elsif include_children && parents_allow_scheduling?(task, time, stack)
                    true
                elsif include_children
                    report_holdoff "not root, and has no running parent", task
                    false
                else
                    report_holdoff "not root, and include_children is false", task
                    false
                end
            end

            def verify_schedule_as_constraints(task, time, stack)
                # "backward scheduling constraint" == "schedule_as",
                # that is in this loop, start_event.schedule_as(parent.start_event)
                task.start_event
                    .each_backward_scheduling_constraint do |scheduled_as_event|
                    scheduled_as_task = scheduled_as_event.task
                    next if stack.include?(scheduled_as_task)

                    if !scheduled_as_task.executable? &&
                       task.depends_on?(scheduled_as_task)
                        return false
                    end

                    begin
                        stack.push task
                        unless can_schedule?(scheduled_as_task, time, stack)
                            report_holdoff(
                                "held by schedule_as(%2)", task, scheduled_as_event
                            )
                            return false
                        end
                    ensure
                        stack.pop
                    end
                end

                true
            end

            def parents_allow_scheduling?(task, time, stack)
                task.each_parent_task.any? do |parent_task|
                    next(true) if parent_task.running?

                    parent_waiting_for_self =
                        parent_waiting_for_self?(task, parent_task)

                    parent_scheduled_as_self =
                        task.start_event.child_object?(
                            parent_task.start_event,
                            Roby::EventStructure::SchedulingConstraints
                        )

                    next(false) unless parent_scheduled_as_self || parent_waiting_for_self
                    next(true) if stack.include?(parent_task)

                    begin
                        stack.push task
                        can_schedule?(parent_task, time, stack)
                    ensure
                        stack.pop
                    end
                end
            end

            def parent_waiting_for_self?(task, parent_task)
                # Special case: check in Dependency if there are some
                # parents for which a forward constraint from +self+ to
                # +parent.start_event+ exists. If it is the case, start
                # the task
                parent_task.start_event.each_backward_temporal_constraint do |constraint|
                    if constraint.respond_to?(:task) && constraint.task == task
                        Schedulers.debug do
                            "Temporal: #{task} has no running parent, but " \
                            "a constraint from #{constraint} to #{parent_task}.start " \
                            "exists. Scheduling."
                        end
                        return true
                    end
                end

                false
            end

            def verify_temporal_constraints(task, time, stack)
                event_filter = lambda do |ev|
                    if ev.respond_to?(:task)
                        ev.task != task &&
                            !stack.include?(ev.task) &&
                            !scheduling_constraints_graph.related_tasks?(ev.task, task)
                    else
                        true
                    end
                end

                start_event = task.start_event
                if (failed_temporal = start_event.find_failed_temporal_constraint(time, &event_filter))
                    report_holdoff "temporal constraints not met (%2: %3)", task, failed_temporal[0], failed_temporal[1]
                    return false
                elsif (failed_occurence = start_event.find_failed_occurence_constraint(true, &event_filter))
                    report_holdoff "occurence constraints not met (%2)", task, failed_occurence
                    return false
                end

                true
            end
        end
    end
end
