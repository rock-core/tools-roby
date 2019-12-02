# frozen_string_literal: true

module Roby
    module Test
        module TeardownPlans
            attr_reader :registered_plans

            def initialize(name)
                super
                @default_teardown_poll = 0.01
            end

            def register_plan(plan)
                raise 'registering nil plan' unless plan

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

            def teardown_registered_plans(teardown_poll: default_teardown_poll,
                                          teardown_warn: 5)
                old_gc_roby_logger_level = Roby.logger.level
                return if registered_plans.all?(&:empty?)

                plans = registered_plans.map do |p|
                    [p, p.execution_engine, Set.new, Set.new] if p.executable?
                end.compact

                counter = 0
                teardown_warn_counter = teardown_warn / teardown_poll
                until plans.empty?
                    plans = plans.map do |plan, engine, last_tasks, last_quarantine|
                        plan_quarantine = plan.quarantined_tasks
                        if counter > teardown_warn_counter
                            Roby.warn "more than #{counter} iterations while trying "\
                                      "to shut down #{plan} after #{self.class.name}#"\
                                      "#{name}, quarantine=#{plan_quarantine.size} "\
                                      "tasks, tasks=#{plan.tasks.size} tasks"
                            if last_tasks != plan.tasks
                                Roby.warn 'Known tasks:'
                                plan.tasks.each do |t|
                                    Roby.warn "  #{t} running=#{t.running?} "\
                                              "finishing=#{t.finishing?}"
                                end
                                last_tasks = plan.tasks.dup
                            end
                            if last_quarantine != plan_quarantine
                                Roby.warn 'Quarantined tasks:'
                                plan_quarantine.each do |t|
                                    Roby.warn "  #{t}"
                                end
                                last_quarantine = plan_quarantine.dup
                            end
                            sleep 1
                        end
                        engine.killall

                        quarantine_and_dependencies =
                            plan.compute_useful_tasks(plan.quarantined_tasks)

                        if quarantine_and_dependencies.size != plan.tasks.size
                            [plan, engine, last_tasks, last_quarantine]
                        end
                    end.compact
                    counter += 1
                    sleep teardown_poll
                end

                registered_plans.each do |plan|
                    plan.clear if plan.tasks.all?(&:pending?)

                    unless plan.empty?
                        Roby.warn(
                            "failed to teardown: #{plan} has #{plan.tasks.size} "\
                            "tasks and #{plan.free_events.size} events, "\
                            "#{plan.quarantined_tasks.size} of which are "\
                            'in quarantine'
                        )

                        unless plan.execution_engine
                            Roby.warn 'this is most likely because this plan '\
                                      'does not have an execution engine. Either '\
                                      'add one or clear the plan in the tests'
                        end
                    end

                    plan.clear
                    if (engine = plan.execution_engine)
                        engine.clear
                        engine.emitted_events.clear
                    end

                    unless plan.transactions.empty?
                        Roby.warn "  #{plan.transactions.size} transactions left "\
                                  'attached to the plan'
                        plan.transactions.each(&:discard_transaction)
                    end
                end
            ensure
                Roby.logger.level = old_gc_roby_logger_level
            end
        end
    end
end
