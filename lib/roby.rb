require 'logger'
require 'roby/support'

module Roby
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::DEBUG
    @logger.progname = "Roby"
    @logger.formatter = lambda { |severity, time, progname, msg| "#{progname}: #{msg}\n" }

    extend Logger::Hierarchy
    extend Logger::Forward
end

require 'roby/event'
require 'roby/task'
require 'roby/state'

