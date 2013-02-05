require 'roby'
require 'optparse'

app = Roby.app
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
    opt.on("-r NAME[:TYPE]", String, "the robot name and type") do |name|
        name, type = name.split(':')
        app.robot name, (type || name)
    end
end

app.testing = true

parser.parse! ARGV
Roby.app.setup
Roby.app.prepare

begin
    r = Test::Unit::AutoRunner.new(true)
    r.process_args(ARGV + testrb_args) or
      abort r.options.banner + " tests..."

    exit r.run
ensure
    Roby.app.cleanup
end

