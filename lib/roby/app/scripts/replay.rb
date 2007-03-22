require 'roby'
require 'optparse'
require 'utilrb/time/to_hms'
gui  = true
play_now = false
initial_displays = []
logdir = nil
goto = nil
speed = 1

parser = OptionParser.new do |opt|
    opt.separator "Common options"
    opt.on("--[no-]gui", "do (not) use a GUI") { |gui| }
    opt.on("--logdir=DIR", String, "the log directory in which we initialize the data sources") do |logdir| end
    opt.on("--play", "start playing after loading the event log") do |play_now| end

    opt.separator "GUI-related options"
    opt.on("--speed=SPEED", Integer, "play speed") do |speed| end
    opt.on("--goto=TIME", String, "go to TIME before playing normally. Time is given relatively to the simulation start") do |goto| 
	goto = Time.from_hms(goto)
    end
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
end
parser.parse!(ARGV)

require File.join(File.dirname(__FILE__), '..', 'run')
require File.join(File.dirname(__FILE__), '..', 'load')
Roby.app.setup

module Roby::Log
end

require 'roby/log/file'
unless gui
    require 'roby/log/console'
    logger = Roby::Log::ConsoleLogger.new(STDOUT)
    Roby::Log.add_logger logger
    Roby::Log.replay(ARGV.shift) do |method, args|
	Roby::Log.log(method, args)
    end
    Roby::Log.flush
    exit
end

require 'roby/log/gui/replay'
app  = Qt::Application.new(ARGV)
main = Replay.new
initial_displays.each do |prc|
    prc.call(main)
end

if ARGV.empty?
    sources = Roby.app.data_sources(logdir)
    sources.each do |source|
	main.add_source(source)
    end
else
    ARGV.each do |file|
	if source = Roby.app.data_source([file])
	    main.add_source(source)
	else
	    STDERR.puts "WARN: unknown file type #{file}"
	end
    end
end

main.show
main.play_speed = speed
if goto
    main.seek(nil)
    main.seek(main.first_sample + (goto - Time.at(0)))
end
if play_now
    main.ui.play.checked = true
end

begin
    app.exec
rescue
    STDERR.puts $!.full_message
end

