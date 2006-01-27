require 'logger'

module Roby
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::DEBUG
    @logger.progname = "Roby"
    @logger.formatter = lambda { |severity, time, progname, msg| "#{progname}: #{msg}\n" }

    class << self
        attr_accessor :logger

        [ :debug, :info, :warn, :error, :fatal, :unknown ].each do |level|
            class_eval <<-EOF
            def #{level}(*args, &proc); @logger.#{level}(*args, &proc) end
            EOF
        end
    end
end

