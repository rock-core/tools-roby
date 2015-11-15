require 'roby/test/self'

module Roby
    module Schedulers
        describe State do
            describe "#pretty_print" do
                it "formats the State object in an easier-to-read format" do
                    pp = PP.new(s = StringIO.new)
                    reporter = Reporting.new
                    reporter.report_pending_non_executable_task("NonExecutableMessageFormatted %1", "TASK")
                    reporter.report_holdoff("NonScheduledMessage %1", "TASK")
                    reporter.state.pretty_print(pp)
                    assert_equal <<-EXPECTED, "#{s.string}\n"
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

