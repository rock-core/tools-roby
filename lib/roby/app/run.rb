require 'roby'

app = Roby.app
require 'optparse'
parser = OptionParser.new do |opt|
    opt.banner = "#{$0} [options] [robot_name [robot_type]]"
    opt.on("--sim", "run in simulation mode") do
        app.simulation
    end
    opt.on("--single", "run in mono-robot mode") do
        app.single
    end
end
parser.parse!(ARGV)

