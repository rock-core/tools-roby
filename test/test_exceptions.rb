# frozen_string_literal: true

require "roby/test/self"

describe Roby do
    describe ".log_level_enabled?" do
        it "returns true if the logger's level is the same than expected" do
            logger = flexmock(level: Logger::WARN)
            assert Roby.log_level_enabled?(logger, :warn)
        end
        it "returns false if the logger's level is higher than expected" do
            logger = flexmock(level: Logger::WARN)
            refute Roby.log_level_enabled?(logger, :info)
        end
        it "knows about forwarded loggers" do
            logger = flexmock(log_level: Logger::WARN)
            assert Roby.log_level_enabled?(logger, :error)
        end
    end

    describe ".log_exceptions" do
        before do
            Roby.disable_colors
        end
        after do
            Roby.enable_colors_if_available
        end

        it "interprets the logger level using the remove" do
            text = "This is a very loooooooong first line\nand a second"
            stub = stub_exception(text)
            logger = flexmock(level: Logger::WARN)
            logger.should_receive(:warn).with(text.split("\n")[0]).once.ordered
            logger.should_receive(:warn).with(text.split("\n")[1]).once.ordered
            Roby.log_exception(stub, logger, :warn)
        end

        it "pretty_prints the exception on the given logger" do
            text = "This is a very loooooooong first line\nand a second"
            stub = stub_exception(text)
            logger = flexmock(level: Logger::WARN)
            logger.should_receive(:warn).with(text.split("\n")[0]).once.ordered
            logger.should_receive(:warn).with(text.split("\n")[1]).once.ordered
            Roby.log_exception(stub, logger, :warn)
        end

        it "can use a forwarded logger" do
            text = "This is a very loooooooong first line\nand a second"
            stub = stub_exception(text)
            logger = flexmock(log_level: Logger::WARN)
            logger.should_receive(:warn).with(text.split("\n")[0]).once.ordered
            logger.should_receive(:warn).with(text.split("\n")[1]).once.ordered
            Roby.log_exception(stub, logger, :warn)
        end

        let :stub_m do
            Class.new(Roby::ExceptionBase) do
                attr_reader :text
                def initialize(text)
                    super([])
                    @text = text
                end

                def pretty_print(pp)
                    pp.text text
                end
            end
        end

        def stub_exception(text)
            stub_m.new(text)
        end

        it "pretty_prints the original exceptions as well" do
            main = stub_exception(main_text = "Main\nMainException")
            sub  = stub_exception(sub_text = "Sub\nSubException")
            flexmock(main, original_exceptions: [sub])

            logger = flexmock(log_level: Logger::WARN)
            logger.should_receive(:warn).with("Main").once.ordered
            logger.should_receive(:warn).with("MainException").once.ordered
            logger.should_receive(:warn).with("Sub").once.ordered
            logger.should_receive(:warn).with("SubException").once.ordered
            Roby.log_exception(main, logger, :warn)
        end
    end
end
