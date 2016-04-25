require 'roby/test/self'

describe Roby do
    describe '.log_exceptions' do
        before do
            Roby.disable_colors
        end
        after do
            Roby.enable_colors_if_available
        end

        it "pretty_prints the exception on the given logger" do
            text = "This is a very loooooooong first line\nand a second"
            stub = stub_exception(text)
            logger = flexmock
            logger.should_receive(:bla).with(Proc).and_yield
            logger.should_receive(:bla).with(text.split("\n")[0]).once.ordered
            logger.should_receive(:bla).with(text.split("\n")[1]).once.ordered
            Roby.log_exception(stub, logger, :bla)
        end

        let :stub_m do
            Class.new(Roby::ExceptionBase) do
                attr_reader :text
                def initialize(text); super([]); @text = text end
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

            logger = flexmock
            logger.should_receive(:bla).with(Proc).and_yield
            logger.should_receive(:bla).with("Main").once.ordered
            logger.should_receive(:bla).with("MainException").once.ordered
            logger.should_receive(:bla).with("Sub").once.ordered
            logger.should_receive(:bla).with("SubException").once.ordered
            Roby.log_exception(main, logger, :bla)
        end
    end
end

