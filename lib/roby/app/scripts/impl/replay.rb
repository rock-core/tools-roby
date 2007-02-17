require 'optparse'
gui  = true
parser = OptionParser.new do |opt|
    opt.on("--[no-]gui", "display events on console or use GUI") { |gui| }
end
parser.parse!(ARGV)
file = ARGV.shift

require File.join(File.dirname(__FILE__), '..', '..', 'config', 'app-run.rb')
config = Roby.app

module Roby::Log
    def self.open(file, &block)
	if file =~ /\.gz$/
	    Zlib::GzipReader.open(file, &block)
	else
	    File.open(file, &block)
	end
    end
end

require 'roby/log/file'
require 'roby/log/relations'
require 'Qt4'

unless gui
    require 'roby/log/console'

    Roby::Log.loggers << Roby::Log::ConsoleLogger.new(STDOUT)
    Roby::Log.open(file, &Roby::Log::FileLogger.method(:replay))
    exit
end

require 'roby/log/relations'
include Roby::Log
app = Qt::Application.new(ARGV)
    require 'roby/log/console'
    Roby::Log.loggers << Roby::Log::ConsoleLogger.new(STDOUT)
relation_display = Display::Relations.new
Roby::Log.loggers << relation_display

# app.main_widget = relation_display.view
relation_display.view.show
Roby::Log.open(file, &Roby::Log::FileLogger.method(:replay))
app.exec

