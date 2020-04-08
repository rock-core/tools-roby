# frozen_string_literal: true

require "roby/test/self"
require "roby/droby/event_logger"
require "roby/droby/logfile/reader"
require "roby/test/droby_log_helpers"

module Roby
    module DRoby
        describe EventLogger do
            include Test::DRobyLogHelpers

            describe "#close" do
                it "does not flush the current cycle" do
                    path = File.join(make_tmpdir, "test.0.log")
                    event_logger = droby_create_event_log path
                    event_logger.close

                    File.open(path, "r") do |io|
                        reader = DRoby::Logfile::Reader.new(io)
                        refute reader.load_one_cycle
                    end
                end
            end
        end
    end
end
