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
                    assert_raises(TeardownFailedError) do
                        teardown_registered_plans(teardown_fail: 0.1)
                    end
                    assert((0.08..0.2).include?(warn_time - tic))

                    matcher = Regexp.new(
                        "more than \\d+ iterations while trying to shut down #{plan} "\
                        "after .*teardown_registered_plans#test_\\d+_warns about "\
                        "tasks that block the plan after teardown_warn "\
                        "seconds, quarantine=0 tasks, tasks=1 tasks")
                    assert_match matcher, messages[0]

                    assert_equal "  #{task} running=true finishing=true", messages[2]
                end
            end
        end
    end
end
