require 'roby'
require 'optparse'
gui  = true
play_now = false
initial_displays = []
logdir = nil

parser = OptionParser.new do |opt|
    opt.on("--[no-]gui", "do (not) use a GUI") { |gui| }
    opt.on("--logdir=DIR", String, "the log directory in which we initialize the data sources") do |logdir| end
    opt.on("--relations=REL1,REL2", Array, "create a relation display with the given relations") do |relations|
	relations.map! do |relname|
	    rel = (Roby::TaskStructure.relations.find { |rel| rel.name =~ /#{relname}/ }) ||
		  (Roby::EventStructure.relations.find { |rel| rel.name =~ /#{relname}/ })

	    unless rel
		STDERR.puts "Unknown relation #{relname}. Available relations are:"
		STDERR.puts "  Tasks: " + Roby::TaskStructure.enum_for(:each_relation).map { |r| r.name.gsub(/.*Structure::/, '') }.join(", ")
		STDERR.puts "  Events: " + Roby::EventStructure.enum_for(:each_relation).map { |r| r.name.gsub(/.*Structure::/, '') }.join(", ")
		exit(1)
	    end

	    rel
	end

	initial_displays << lambda do |gui|
	    relation_display = gui.add_display('Relations')
	    relations.each do |rel|
		relation_display.enable_relation(rel)
	    end
	end
    end
    opt.on("--play", "start playing after loading the event log") do |play_now| end
end
parser.parse!(ARGV)
if !gui
    file = ARGV.shift
end

require File.join(File.dirname(__FILE__), '..', '..', 'config', 'app-run.rb')
config = Roby.app

module Roby::Log
end

require 'roby/log/file'
unless gui
    require 'roby/log/console'
    Roby::Log.loggers << Roby::Log::ConsoleLogger.new(STDOUT)
    Roby::Log.replay(file) do |method, args|
	Roby::Log.log(method, args)
    end
    exit
end

require 'roby/log/gui/replay'
app  = Qt::Application.new(ARGV)
main = Replay.new
initial_displays.each do |prc|
    prc.call(main)
end

sources = Roby.app.data_sources(logdir)
sources.each do |source|
    main.add_source(source)
end

main.show
if play_now
    main.ui.play.checked = true
end
app.exec

