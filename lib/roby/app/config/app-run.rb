require 'roby/app'

app = Roby.app
require 'optparse'
parser = OptionParser.new do |opt|
    opt.on("--sim", "run in simulation mode") do
	app.simulation
    end
    opt.on("--single", "run in mono-robot mode") do
	app.single
    end
end
parser.parse!(ARGV)
app.robot ARGV[0], (ARGV[1] || ARGV[0])

require File.join(File.dirname(__FILE__), 'app-load.rb')
app.setup

