require 'roby'
require 'optparse'

app = Roby.app
app.require_app_dir
app.public_logs = false

testrb_args = []
parser = OptionParser.new do |opt|
    opt.on("-s", "--sim", "run tests in simulation mode") do |val|
	Roby.app.simulation = val
    end
    opt.on("-k", "--keep-logs", "keep all logs") do |val|
	Roby.app.public_logs = true
    end
    opt.on("-i", "--interactive", "allow user interaction during tests") do |val|
	Roby.app.automatic_testing = false
    end
    opt.on("-n", "--name NAME", String, "run tests matching NAME") do |name|
	testrb_args << "-n" << name
    end
    Roby::Application.common_optparse_setup(opt)
end

app.testing = true

remaining_arguments = parser.parse(ARGV)

Roby.display_exception do
    Roby.app.setup
    Roby.app.prepare

    begin
        remaining_arguments.each do |file|
            require File.expand_path(file)
        end

        MiniTest::Unit.new.run
    ensure
        Roby.app.cleanup
    end
end


