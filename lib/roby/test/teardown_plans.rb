# frozen_string_literal: true

module Roby
    module Test
        # Implementation of the teardown procedure
        #
        # The main method {#teardown_registered_plans} is used by tests on teardown
        # to attempt to clean up running tasks, and handle corner cases (i.e. tasks
        # that do not want to be stopped) as best as possible
        module TeardownPlans
            attr_reader :registered_plans

            include ExpectExecution

            def initialize(name)
                super
                @default_teardown_poll = 0.01
            end

            def register_plan(plan)
                raise "registering nil plan" unless plan

                (@registered_plans ||= []) << plan
            end

            def clear_registered_plans
                registered_plans.each do |p|
                    if p.respond_to?(:execution_engine)
                        p.execution_engine.killall
                        p.execution_engine.reset
                        execute(plan: p) { p.clear }
                    end
                end
                registered_plans.clear
            end

            attr_accessor :default_teardown_poll

            class TeardownFailedError < RuntimeError
            end

            # Clear all plans registered with {#registered_plans}
            #
            # It first attempts an orderly shutdown, then goes to try to
            # force-stop all the tasks that can and will finally clear the data
            # structure without caring for running tasks (something that's bad
            # in principle, but is usually fine during unit tests)
            #
            # @param [Float] teardown_poll polling period in seconds
            # @param [Float] teardown_warn warn that something is wrong (holding
            #   up cleanup) after this many seconds
            # @param [Float] teardown_force try to force-kill tasks after this many
            #   seconds from the start
            # @param [Float] teardown_fail stop trying to stop tasks and clear the
            #   data structure after this many seconds from the start
            #
            # For instance, the default of teardown_force=10 and teardown_fail=20
            # will try an orderly stop for 10 seconds and a forced stop for 10s.
            def teardown_registered_plans(
                teardown_poll: default_teardown_poll,
                teardown_warn: 5, teardown_fail: 20, teardown_force: teardown_fail / 2
            )
                old_gc_roby_logger_level = Roby.logger.level
                return if registered_plans.all?(&:empty?)

                success = teardown_killall(teardown_warn, teardown_force, teardown_poll)

                unless success
                    Roby.warn "clean teardown failed, trying to force-kill all tasks"
                    teardown_forced_killall(
                        teardown_warn, (teardown_fail - teardown_force), teardown_poll
                    )
                end

                registered_plans.each do |plan|
                    teardown_clear(plan)
                end

                raise TeardownFailedError, "failed to tear down plan" unless success
            ensure
                Roby.logger.level = old_gc_roby_logger_level
            end

            # @api private
            #
            # Try to cleanly kill all running tasks in the registered plans
            #
            # @return [Boolean] true if successful, false otherwise
            def teardown_killall(
                teardown_warn, teardown_fail, teardown_poll
            )
                executable_plans = registered_plans.find_all(&:executable?)
                plans = executable_plans.map do |p|
                    [p, p.execution_engine, Set.new, Set.new]
                end

                start_time = now = Time.now
                warn_deadline = now + teardown_warn
                fail_deadline = now + teardown_fail
                until plans.empty? || (now > fail_deadline)
                    plans = plans.map do |plan, engine, last_tasks, last_quarantine|
                        plan_quarantine = plan.quarantined_tasks
                        if now > warn_deadline
                            teardown_warn(start_time, plan, last_tasks, last_quarantine)
                            last_tasks = plan.tasks.dup
                            last_quarantine = plan_quarantine.dup
                        end
                        engine.killall

                        quarantine_and_dependencies =
                            plan.compute_useful_tasks(plan.quarantined_tasks)

                        if quarantine_and_dependencies.size != plan.tasks.size
                            [plan, engine, last_tasks, last_quarantine]
                        end
                    end
                    plans = plans.compact
                    sleep teardown_poll

                    now = Time.now
                end

                # NOTE: this is NOT plan.empty?. We stop processing plans that
                # are made of quarantined tasks and their dependencies, but
                # still report an error when they exist
                return true if executable_plans.all?(&:empty?)

                executable_plans
                    .find_all { |p| !p.empty? }
                    .each { |plan| teardown_warn(start_time, plan, [], [], force: true) }

                false
            end

            # @api private
            #
            # Force-kill all that can be
            #
            # This clears all dependency relations between tasks to let the garbage
            # collector get them unordered, and force-kills the execution agents
            def teardown_forced_killall(
                teardown_warn_counter, teardown_fail_counter, teardown_poll
            )
                registered_plans.each do |plan|
                    execution_agent_g =
                        plan.task_relation_graph_for(TaskStructure::ExecutionAgent)
                    to_stop = execution_agent_g.each_edge.find_all do |_, child, _|
                        child.running? && !child.stop_event.pending? &&
                            child.stop_event.controlable?
                    end

                    execute(plan: plan) do
                        plan.each_task do |t|
                            t.clear_relations(
                                remove_internal: false, remove_strong: false
                            )
                        end
                        to_stop.each { |_, child, _| child.stop! }
                    end
                end

                teardown_killall(
                    teardown_warn_counter, teardown_fail_counter, teardown_poll
                )
            end

            def teardown_warn(start_time, plan, last_tasks, last_quarantine, force: false)
                changed_since_last_warning =
                    (last_tasks != plan.tasks) ||
                    (last_quarantine != plan.quarantined_tasks)

                return unless force || changed_since_last_warning

                duration = Integer(Time.now - start_time)
                Roby.warn "trying to shut down #{plan} for #{duration}s after "\
                          "#{self.class.name}##{name}, "\
                          "quarantine=#{plan.quarantined_tasks.size} tasks, "\
                          "tasks=#{plan.tasks.size} tasks"

                Roby.warn "Known tasks:"
                plan.tasks.each do |t|
                    Roby.warn "  #{t} running=#{t.running?} finishing=#{t.finishing?}"
                end

                Roby.warn "Quarantined tasks:"
                plan.quarantined_tasks.each do |t|
                    Roby.warn "  #{t}"
                end

                nil
            end

            # @api private
            #
            # Try to cleanly kill all running tasks in the registered plans
            #
            # @return [Boolean] true if successful, false otherwise
            def teardown_clear(plan)
                if plan.tasks.any? { |t| t.starting? || t.running? }
                    Roby.warn(
                        "failed to teardown: #{plan} has #{plan.tasks.size} "\
                        "tasks and #{plan.free_events.size} events, "\
                        "#{plan.quarantined_tasks.size} of which are in quarantine"
                    )

                    unless plan.execution_engine
                        Roby.warn "this is most likely because this plan "\
                                  "does not have an execution engine. Either "\
                                  "add one or clear the plan in the tests"
                    end
                end

                execute(plan: plan) { plan.clear }

                if (engine = plan.execution_engine)
                    engine.clear
                    engine.emitted_events.clear
                end

                unless plan.transactions.empty?
                    Roby.warn "  #{plan.transactions.size} transactions left "\
                                "attached to the plan"
                    plan.transactions.each(&:discard_transaction)
                end

                nil
            end
        end
    end
end
