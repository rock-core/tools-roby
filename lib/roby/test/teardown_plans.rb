module Roby
    module Test
        module TeardownPlans
            attr_reader :registered_plans

            def register_plan(plan)
                (@registered_plans ||= Array.new) << plan
            end

            def clear_registered_plans
                registered_plans.each do |p|
                    engine = p.execution_engine
                    while engine && engine.running?
                        engine.quit
                        engine.join rescue nil
                    end
                    p.clear
                end

                registered_plans.clear
            end

            def teardown_registered_plans
                old_gc_roby_logger_level = Roby.logger.level
                if self.registered_plans.all? { |p| p.empty? }
                    return
                end

                plans = self.registered_plans.map do |p|
                    if p.executable?
                        [p, p.execution_engine, p.known_tasks.to_set, p.gc_quarantine.to_set]
                    end
                end.compact

                counter = 0
                while !plans.empty?
                    plans = plans.map do |plan, engine, last_known_tasks, last_quarantine|
                        if counter > 100
                            Roby.warn "more than #{counter} iterations while trying to shut down #{plan}, quarantine=#{plan.gc_quarantine.size} tasks, tasks=#{plan.known_tasks.size} tasks"
                            if last_known_tasks != plan.known_tasks
                                Roby.warn "Known tasks:"
                                plan.known_tasks.each do |t|
                                    Roby.warn "  #{t}"
                                end
                                last_known_tasks = plan.known_tasks.dup
                            end
                            if last_quarantine != plan.gc_quarantine
                                Roby.warn "Quarantined tasks:"
                                plan.gc_quarantine.each do |t|
                                    Roby.warn "  #{t}"
                                end
                                last_quarantine = plan.gc_quarantine.dup
                            end
                            sleep 1
                        end
                        engine.killall
                        
                        if plan.gc_quarantine.size != plan.known_tasks.size
                            [plan, engine, last_known_tasks, last_quarantine]
                        end
                    end.compact
                    counter += 1
                end

                registered_plans.each do |plan|
                    if !plan.empty?
                        if plan.known_tasks.all? { |t| t.pending? }
                            plan.clear
                        else
                            Roby.warn "failed to teardown: #{plan} has #{plan.known_tasks.size} tasks and #{plan.free_events.size} events, #{plan.gc_quarantine.size} of which are in quarantine"
                            if !plan.execution_engine
                                Roby.warn "this is most likely because this plan does not have an execution engine. Either add one or clear the plan in the tests"
                            end
                        end
                    end
                    plan.clear
                    if engine = plan.execution_engine
                        engine.clear
                        engine.emitted_events.clear
                    end

                    if !plan.transactions.empty?
                        Roby.warn "  #{plan.transactions.size} transactions left attached to the plan"
                        plan.transactions.each do |trsc|
                            trsc.discard_transaction
                        end
                    end
                end

            ensure
                Roby.logger.level = old_gc_roby_logger_level
            end
        end
    end
end

