# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Test
        describe TeardownPlans do
            describe "#teardown_registered_plans" do
                it "warns about tasks that block the plan after teardown_warn seconds" do
                    task_m = Roby::Task.new_submodel do
                        event(:stop) { |event| }
                    end
                    plan.add(task = task_m.new)

                    messages = []
                    warn_time = nil
                    flexmock(Roby).should_receive(:warn).and_return do |msg|
                        warn_time ||= Time.now
                        messages << msg
                        execution_engine.once { task.stop_event.emit }
                    end

                    execute { task.start_event.emit }
                    tic = Time.now
                    teardown_registered_plans(
                        teardown_warn: 0.1, teardown_force: 10, teardown_fail: 0.5
                    )
                    assert((0.08..0.2).include?(warn_time - tic))

                    matcher = Regexp.new(
                        "trying to shut down #{plan} for \\d+s "\
                        "after .*teardown_registered_plans#test_\\d+_warns about "\
                        "tasks that block the plan after teardown_warn "\
                        "seconds, quarantine=0 tasks, tasks=1 tasks")
                    assert_match matcher, messages[0]

                    assert_equal "  #{task} running=true finishing=true", messages[2]
                end

                it "force-kills deployments after teardown_force seconds and reports "\
                   "a teardown failure" do
                    task_m = Roby::Task.new_submodel { event(:stop) { |event| } }
                    deployment_m = Roby::Task.new_submodel do
                        terminates
                        event :ready
                    end

                    plan.add(task = task_m.new)
                    task.executed_by(deployment = deployment_m.new)

                    execute do
                        deployment.start_event.emit
                        deployment.ready_event.emit
                        task.start_event.emit
                    end

                    tic = Time.now
                    assert_raises(TeardownPlans::TeardownFailedError) do
                        warns = capture_log(Roby, :warn) do
                            teardown_registered_plans(
                                teardown_warn: 10, teardown_force: 0.2, teardown_fail: 0.4
                            )
                        end
                        assert_equal(
                            "clean teardown failed, trying to force-kill all tasks",
                            warns[0]
                        )
                    end
                    assert (0.15..0.25).include?(task.stop_event.last.time - tic)
                    assert plan.empty?
                end

                it "removes dependency relationships between tasks to let the GC "\
                   "try to clean them up" do
                    task_m = Roby::Task.new_submodel { event(:stop) { |event| } }

                    plan.add(child = Roby::Tasks::Simple.new)
                    deployment_m = Roby::Task.new_submodel do
                        event :ready

                        poll do
                            stop_event.emit if child.finished? && stop_event.pending?
                        end

                        event :stop do |_|
                        end
                    end

                    plan.add(task = task_m.new)
                    task.executed_by(deployment = deployment_m.new)
                    task.depends_on child

                    execute do
                        deployment.start_event.emit
                        deployment.ready_event.emit
                        task.start_event.emit
                        child.start_event.emit
                    end

                    tic = Time.now
                    assert_raises(TeardownPlans::TeardownFailedError) do
                        warns = capture_log(Roby, :warn) do
                            teardown_registered_plans(
                                teardown_warn: 10, teardown_force: 0.2, teardown_fail: 0.4
                            )
                        end

                        assert_equal(
                            "clean teardown failed, trying to force-kill all tasks",
                            warns[0]
                        )
                    end
                    assert (0.15..0.25).include?(task.stop_event.last.time - tic)
                end
            end
        end
    end
end
