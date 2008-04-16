require 'active_support/core_ext/string/inflections'
class String # :nodoc: all
    include ActiveSupport::CoreExtensions::String::Inflections
end

require 'roby/graph'
require 'facets/kernel/constant'
require 'utilrb/enumerable'
require 'utilrb/time/to_hms'
require 'utilrb/module/cached_enum'
require 'utilrb/logger'
require 'utilrb/gc/force'
require 'utilrb/hash/to_sym_keys'
require 'utilrb/array/to_s'
require 'utilrb/hash/to_s'
require 'utilrb/set/to_s'

class IO
    def ask(question, default, output_io = STDOUT)
	output_io.print question
	output_io.flush
	loop do
	    answer = readline.chomp.downcase
	    if answer.empty?
		return default
	    elsif answer == 'y'
		return true
	    elsif answer == 'n'
		return false
	    else
		output_io.print "\nInvalid answer, try again: "
		output_io.flush
	    end
	end
    end
end

module Enumerable
    def empty?
	for i in self
	    return false
	end
	true
    end
end

class Module
    # Defines a new constant under a given module
    # :call-seq
    #   define_under(name, value)   ->              value
    #   define_under(name) { ... }  ->              value
    #
    # In the first form, the method gets its value from its argument. 
    # In the second case, it calls the provided block
    def define_under(name, value = nil)
	if old = constants.find { |cn| cn == name.to_s }
	    return const_get(old)
	else
            const_set(name, (value || yield))
        end
    end
end

class Thread
    def send_to(object, name, *args, &prc)
	if Thread.current == self
	    object.send(name, *args, &prc)
	else
	    @msg_queue ||= Queue.new
	    @msg_queue << [ object, name, args, prc ]
	end
    end
    def process_events
        @msg_queue ||= Queue.new
	loop do
            object, name, args, block = *@msg_queue.deq(true)
            object.send(name, *args, &block)
        end
    rescue ThreadError
    end
end

module Roby
    @logger = Logger.new(STDERR)
    @logger.level = Logger::WARN
    @logger.progname = "Roby"
    @logger.formatter = lambda { |severity, time, progname, msg| "#{time.to_hms} (#{progname}) #{msg}\n" }

    extend Logger::Hierarchy
    extend Logger::Forward
end

