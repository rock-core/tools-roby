# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Schedulers
        describe State do
            describe "#pretty_print" do
                it "formats the State object in an easier-to-read format" do
                    pp = PP.new(s = StringIO.new)
                    state = State.new
                    state.report_pending_non_executable_task("NonExecutableMessageFormatted %1", "TASK")
                    state.report_holdoff("NonScheduledMessage %1", "TASK")
                    state.pretty_print(pp)
                    assert_equal <<~EXPECTED, "#{s.string}\n"
                        Pending non-executable tasks
                          NonExecutableMessageFormatted TASK
                        Non scheduled tasks
                          "TASK"
                            NonScheduledMessage TASK
                    EXPECTED
                end
            end
        end
    end
end
