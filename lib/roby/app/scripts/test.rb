require 'roby'
require 'optparse'

testrb_args = []
parser = OptionParser.new do |opt|
    opt.on("-s", "--sim", "run tests in simulation mode") do |val|
	Roby.app.simulation = val
    end
    opt.on("-k", "--keep-logs", "keep all logs") do |val|
	Roby.app.testing_keep_logs = val
    end
    opt.on("-o", "--overwrite-oldlogs", "if there are logs for the same test case, overwrite them") do |val|
	Roby.app.testing_overwrites_logs = val
    end
    opt.on("-i", "--interactive", "allow user interaction during tests") do |val|
	Roby.app.automatic_testing = false
    end
    opt.on("-n", "--name NAME", String, "run tests matching NAME") do |name|
	testrb_args << "-n" << name
    end
end
parser.parse! ARGV
Roby.app.testing = true
require 'roby/test/testcase'

app = Roby.app
app.setup

r = Test::Unit::AutoRunner.new(true)
r.process_args(ARGV + testrb_args) or
  abort r.options.banner + " tests..."

if r.filters.empty?
    r.filters << lambda do |t|
	t.class != Roby::Test::TestCase
    end
end

exit r.run

