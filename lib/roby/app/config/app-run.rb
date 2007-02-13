require 'roby/app/config'

config = Roby::Application.config
require 'optparse'
parser = OptionParser.new do |opt|
    opt.on("--sim", "run in simulation mode") do
	config.simulation
    end
    opt.on("--single", "run in mono-robot mode") do
	config.single
    end
end
parser.parse!(ARGV)
config.robot ARGV[0], (ARGV[1] || ARGV[0])

require File.join(File.dirname(__FILE__), 'app-load.rb')
config.setup

