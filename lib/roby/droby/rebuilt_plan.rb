# frozen_string_literal: true

module Roby
    module DRoby
        # Plan object that has been rebuilt from an log event stream
        #
        # It stores additional event propagation information extracted from the
        # stream
        class RebuiltPlan < Roby::Plan
            # The set of tasks that have been finalized since the last call to
            # #clear_integrated
            attr_reader :finalized_tasks
            # The set of free event generators that have been finalized since
            # the last call to #clear_integrated
            attr_reader :finalized_events
            # The set of tasks that got garbage collected.  For display
            # purposes, they only get removed from the plan at the next cycle.
            attr_reader :garbaged_tasks
            # The set of events that got garbage collected.  For display
            # purposes, they only get removed from the plan at the next cycle.
            attr_reader :garbaged_events
            # The set of generators that have been called since the last call to
            # #clear_integrated
            #
            # @return [Array<EventGenerator>]
            attr_reader :called_generators
            # The set of events emitted since the last call to
            # #clear_integrated
            #
            # @return [Array<Event>]
            attr_reader :emitted_events
            # The set of event propagations that have been recorded since the
            # last call to # #clear_integrated
            attr_reader :propagated_events
            # The set of events that have failed to emit since the last call to
            # #clear_integrated
            attr_reader :failed_emissions
            # The set of tasks that failed to start since the last call to
            # #clear_integrated
            attr_reader :failed_to_start
            # The set of exceptions propagated since the last call to
            # #clear_integrated
            attr_reader :propagated_exceptions
            # The list of scheduler states since the last call to
            # #clear_integrated
            #
            # @return [Array<Schedulers::State>]
            attr_reader :scheduler_states

            def initialize
                super
                @finalized_tasks = Set.new
                @finalized_events = Set.new
                @garbaged_tasks = Set.new
                @garbaged_events = Set.new
                @called_generators = []
                @emitted_events = []
                @propagated_events = []
                @failed_emissions = []
                @failed_to_start = []
                @propagated_exceptions = []
                @scheduler_states = []
            end

            def merge(plan)
                super

                if plan.kind_of?(RebuiltPlan)
                    finalized_tasks.merge(plan.finalized_tasks)
                    finalized_events.merge(plan.finalized_events)
                    garbaged_tasks.merge(plan.garbaged_tasks)
                    garbaged_events.merge(plan.garbaged_events)
                    called_generators.concat(plan.called_generators)
                    emitted_events.concat(plan.emitted_events)
                    propagated_events.concat(plan.propagated_events)
                    failed_emissions.concat(plan.failed_emissions)
                    failed_to_start.concat(plan.failed_to_start)
                    propagated_exceptions.concat(plan.propagated_exceptions)
                    scheduler_states.concat(plan.scheduler_states)
                end
            end

            def finalize_event(object, timestamp = nil)
                # Don't do anything. Due to the nature of the plan replay
                # mechanisms, tasks that are already finalized can very well be
                # kept included in plans. That is something that would be caught
                # by the finalization paths in Plan
                object.clear_relations
            end

            def finalize_task(object, timestamp = nil)
                # Don't do anything. Due to the nature of the plan replay
                # mechanisms, tasks that are already finalized can very well be
                # kept included in plans. That is something that would be caught
                # by the finalization paths in Plan
                object.clear_relations
            end

            def clear
                super
                clear_integrated
            end

            # A consolidated representation of the states in {#scheduler_states}
            #
            # It removes duplicates, and removes "non-scheduled" reports for
            # tasks that have in fine been scheduled
            #
            # @return [Schedulers::State]
            def consolidated_scheduler_state
                state = Schedulers::State.new
                scheduler_states.each do |s|
                    state.pending_non_executable_tasks = s.pending_non_executable_tasks
                    s.called_generators.each do |g|
                        state.non_scheduled_tasks.delete(g.task)
                        state.called_generators << g
                    end
                    s.non_scheduled_tasks.each do |task, reports|
                        reports.each do |report|
                            unless state.non_scheduled_tasks[task].include?(report)
                                state.non_scheduled_tasks[task] << report
                            end
                        end
                    end
                    s.actions.each do |task, reports|
                        reports.each do |report|
                            unless state.actions[task].include?(report)
                                state.actions[task] << report
                            end
                        end
                    end
                end
                state
            end

            def clear_integrated
                called_generators.clear
                emitted_events.clear
                finalized_tasks.clear
                finalized_events.clear
                propagated_events.clear
                failed_emissions.clear
                failed_to_start.clear
                scheduler_states.clear
                propagated_exceptions.clear

                garbaged_tasks.each do |task|
                    # Do remove the GCed object. We use object.finalization_time
                    # to store the actual finalization time. Pass it again to
                    # #remove_object so that it does not get reset to Time.now
                    remove_task!(task, task.finalization_time)
                end
                garbaged_tasks.clear
                garbaged_events.each do |event|
                    remove_free_event!(event, event.finalization_time)
                end
                garbaged_events.clear
            end
        end
    end
end
