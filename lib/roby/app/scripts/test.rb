require 'roby'
require 'roby/app'
require 'roby/test/testcase'
require 'test/unit'

testrb_args = []
parser = OptionParser.new do |opt|
    opt.on("--sim", "run tests in simulation mode") do |val|
	if val
	    Roby.app.simulation
	end
    end
    opt.on("-n", "--name NAME", String, "run tests matching NAME") do |name|
	testrb_args << "-n" << name
    end
end
parser.parse! ARGV

r = Test::Unit::AutoRunner.new(true)
r.process_args(ARGV + testrb_args) or
  abort r.options.banner + " tests..."

if r.filters.empty?
    r.filters << lambda do |t|
	t.class != Roby::Test::TestCase
    end
end

exit r.run

