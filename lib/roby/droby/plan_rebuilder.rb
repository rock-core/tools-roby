require 'roby/droby/rebuilt_plan'

module Roby
    module DRoby
        # This class rebuilds a plan structure from events saved by
        # {EventLogger}
        #
        # The data has to be fed cycle-by-cycle to the {#process_cycle} method
        class PlanRebuilder
            # The object that does ID-to-object mapping
            attr_reader :object_manager
            # The object that unmarshals the data
            attr_reader :marshal

            # The Plan object into which we rebuild information
            attr_reader :plan

            # A hash representing the statistics for this execution cycle
            attr_reader :stats
            # A representation of the state for this execution cycle
            attr_reader :state
            # A hash that stores (at a high level) what changed since the last
            # call to #clear_integrated
            #
            # Don't manipulate directly, but use the announce_* and
            # has_*_changes? methods
            attr_reader :changes
            # A set of EventFilter objects that list the labelling objects /
            # filters applied on the event stream
            attr_reader :event_filters

            # The time of the first processed cycle
            attr_reader :start_time
            # The time of the last processed log item
            attr_reader :current_time

            def initialize(plan: RebuiltPlan.new)
                @plan = plan
                @object_manager = ObjectManager.new(droby_id)
                @marshal = Marshal.new(object_manager, nil)

                clear_changes
                @stats = Hash.new
            end

            def analyze_stream(event_stream, until_cycle = nil)
                while !event_stream.eof? && (!until_cycle || (cycle_index && cycle_index == until_cycle))
                    begin
                        data = event_stream.read
                        interesting = process(data)
                        if block_given?
                            interesting = yield
                        end

                        if interesting
                            relations = if !has_structure_updates? && !history.empty?
                                            history.last.relations
                                        end

                            history << snapshot(relations)
                        end

                    ensure
                        clear_integrated
                    end
                end
            end

            # The starting time of the last processed cycle
            #
            # @return [Time]
            def cycle_start_time
                if stats[:start] && stats[:real_start]
                    Time.at(*stats[:start]) + stats[:real_start]
                end
            end

            # The starting time of the last processed cycle
            def cycle_end_time
                Time.at(*stats[:start]) + stats[:end]
            end

            # The cycle index of the last processed cycle
            def cycle_index
                stats[:cycle_index]
            end

            # True if there are stuff recorded in the last played cycles that
            # demand a snapshot to be created
            def has_interesting_events?
                has_structure_updates? || has_event_propagation_updates?
            end

            def clear
                plan.clear
                object_manager.clear
            end

            # Processes one cycle worth of data coming from an EventStream,
            # updating the plan
            #
            # It returns true if there was something noteworthy in there, and
            # false otherwise.
            def process_one_cycle(data)
                data.each_slice(4) do |m, sec, usec, args|
                    process_one_event(m, sec, usec, args)
                end
            end

            def process_one_event(m, sec, usec, args)
                time = Time.at(sec, usec)
                @current_time = time

                begin
                    send(m, time, *args)
                rescue Interrupt
                    raise
                rescue Exception => e
                    display_args = args.map do |obj|
                        case obj
                        when NilClass then 'nil'
                        when Time then obj.to_hms
                        else (obj.to_s rescue "failed_to_s")
                        end
                    end

                    raise e, "#{e.message} while serving #{m}(#{display_args.join(", ")})", e.backtrace
                end
                nil
            end

            def local_object(object)
                marshal.local_object(object)
            end

            def clear_integrated
                clear_changes
                if !plan.garbaged_objects.empty?
                    announce_structure_update
                    announce_state_update
                end
                plan.clear_integrated
            end

            def clear_changes
                @changes = Hash[
                    state: false,
                    structure: false,
                    event_propagation: false]
            end

            def self.update_type(type)
                define_method("announce_#{type}_update") do
                    @changes[type] = true
                end
                define_method("has_#{type}_updates?") do
                    !!@changes[type]
                end
            end

            # @!method: announce_structure_update
            # @!method: has_structure_updates?
            update_type :structure

            # @!method: announce_state_update
            # @!method: has_state_updates?
            update_type :state

            # @!method: announce_event_propagation_update
            # @!method: has_event_propagation_updates?
            update_type :event_propagation

            def register_executable_plan(time, plan_id)
                object_manager.register_object(plan, nil => plan_id)
            end

            def merged_plan(time, plan_id, merged_plan)
                merged_plan = local_object(merged_plan)
                tasks_and_events = merged_plan.known_tasks.to_a +
                    merged_plan.free_events.to_a +
                    merged_plan.task_events.to_a

                local_object(plan).merge(merged_plan)
                tasks_and_events.each do |obj|
                    obj.addition_time = time
                end
            end

            def added_edge(time, parent, child, relations, info)
                parent = local_object(parent)
                child  = local_object(child)
                rel    = local_object(relations.first)
                info   = local_object(info)
                g = parent.relation_graph_for(rel)
                g.add_edge(parent, child, info)
            end

            def updated_edge_info(time, parent, child, relation, info)
                parent = local_object(parent)
                child  = local_object(child)
                rel    = local_object(relation)
                info   = local_object(info)
                g = parent.relation_graph_for(rel)
                g.set_edge_info(parent, child, info)
            end

            def removed_edge(time, parent, child, relations)
                parent = local_object(parent)
                child  = local_object(child)
                rel    = local_object(relations.first)
                g = parent.relation_graph_for(rel)
                g.remove_edge(parent, child)
            end

            def plan_status_change(time, object, status)
                object = local_object(object)
                if status == :normal
                    if object.respond_to?(:to_task)
                        plan.unmark_mission(object)
                    end
                    plan.unmark_permanent(object)
                elsif status == :permanent
                    plan.add_permanent(object)
                elsif status == :mission
                    plan.add_mission(object)
                end
            end

            def garbage(time, plan, object)
                plan = local_object(plan)
                object = local_object(object)
                plan.garbaged_objects << object
            end

            def finalized_event(time, plan_id, event)
                plan  = local_object(plan_id)
                event = local_object(event)
                event.finalization_time = time
                if !plan.garbaged_objects.include?(event) && event.root_object?
                    plan.finalized_events << event
                    plan.remove_object(event)
                    announce_structure_update
                end
                object_manager.deregister_object(event)
            end
            def finalized_task(time, plan_id, task)
                plan = local_object(plan_id)
                task = local_object(task)
                task.finalization_time = time
                if !plan.garbaged_objects.include?(task)
                    plan.finalized_tasks << task
                    plan.remove_object(task)
                    announce_structure_update
                end
                object_manager.deregister_object(task)
            end

            def task_arguments_updated(time, task, key, value)
                task  = local_object(task)
                value = local_object(value)
                task.arguments.force_merge!(key => value)
            end

            def task_failed_to_start(time, task, reason)
                task   = local_object(task)
                reason = local_object(reason)
                task.plan.failed_to_start << [task, reason]
                task.failed_to_start!(reason, time)
                announce_event_propagation_update
            end

            def generator_fired(time, event)
                event     = local_object(event)
                generator = event.generator
                plan      = event.plan

                generator.history << event
                generator.instance_eval { @emitted = true }
                if generator.respond_to?(:task)
                    generator.task.update_task_status(event)
                end
                generator.plan.emitted_events << event
                announce_event_propagation_update
            end

            def generator_emit_failed(time, generator, error)
                generator = local_object(generator)
                error = local_object(error)
                generator.plan.failed_emissions << [generator, error]
                announce_event_propagation_update
            end

            def generator_propagate_events(time, is_forwarding, events, generator)
                events    = local_object(events)
                generator = local_object(generator)
                generator.plan.propagated_events << [is_forwarding, events, generator]
                announce_event_propagation_update
            end

            def generator_unreachable(time, generator, reason)
                local_object(generator).unreachable!(local_object(reason))
            end

            def exception_notification(time, plan_id, mode, error, involved_objects)
                local_object(plan_id).propagated_exceptions << [mode, local_object(error), local_object(involved_objects)]
            end

            def report_scheduler_state(time, plan, pending_non_executable_tasks, called_generators, non_scheduled_tasks)
                plan = local_object(plan)
                state = Schedulers::State.new
                state.pending_non_executable_tasks = local_object(pending_non_executable_tasks)
                state.called_generators = local_object(called_generators)
                state.non_scheduled_tasks = local_object(non_scheduled_tasks)

                plan.scheduler_states << state
            end

            def cycle_end(time, timings)
                @state = timings.delete(:state)
                @stats = timings
                @start_time ||= self.cycle_start_time
                announce_state_update
            end
        end
    end
end

