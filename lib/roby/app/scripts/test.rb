require 'roby'
require 'roby/app'
require 'roby/test/testcase'
require 'test/unit'

parser = OptionParser.new do |opt|
    opt.on("--[no-]sim", "run tests for simulation mode") do |val|
	if val
	    Roby.app.simulation
	end
    end
end
parser.parse! ARGV

r = Test::Unit::AutoRunner.new(true)
r.process_args(ARGV) or
  abort r.options.banner + " tests..."

if r.filters.empty?
    r.filters << lambda do |t|
	t.class != Roby::Test::TestCase
    end
end

exit r.run

