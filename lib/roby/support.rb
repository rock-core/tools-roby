require 'active_support/core_ext/string/inflections'
class String # :nodoc: all
    include ActiveSupport::CoreExtensions::String::Inflections
end

require 'thread'
require 'monitor'
require 'roby/graph'
require 'facet/kernel/constant'
require 'facet/module/dirname'
require 'utilrb/enumerable'
require 'utilrb/time/to_hms'
require 'utilrb/module/cached_enum'
require 'utilrb/logger'
require 'utilrb/gc/force'
require 'utilrb/hash/to_sym_keys'
require 'utilrb/array/to_s'
require 'utilrb/hash/to_s'
require 'utilrb/set/to_s'

# Create a new thread and forward all messages
# to the +forward_to+ object given at initialization.
# The messages are sent in the new thread.
class ThreadServer
    class Quit < RuntimeError; end
    attr_reader :thread, :forwarded
    attr_reader :empty_queue

    include MonitorMixin

    # Create the new thread server. +forward_to+ is the server
    # object. If +multiplex+ is true, then +forward_to+
    # is supposed to respond to demux(commands), where
    # commands is an array of [method, *args, block] elements,
    # where block is the block given at method call or nil.
    #
    # The server object can raise ThreadServer::Quit to 
    # quit the loop
    def initialize(forward_to, multiplex = false)
	super()

	@forwarded  = forward_to
	@queue	    = Queue.new
	@multiplex  = multiplex

	started = false
	started_signal = new_cond
	@empty_queue = new_cond

	@thread = Thread.new do
	    Thread.current.priority = 0
	    Thread.current.abort_on_exception = true
	    begin
		synchronize do
		    started = true
		    started_signal.signal
		end
		loop { process_messages }
	    rescue ThreadServer::Quit
	    end
	end
	
	synchronize { started_signal.wait_until { started } }
    end

    attr_accessor :multiplex

    def process_messages
	message = @queue.pop

	if multiplex
	    messages = []
	    messages << message
	    while message = (@queue.pop(true) rescue nil)
		messages << message
	    end

	    forwarded.demux(messages)
	else
	    block = message.pop
	    forwarded.send(*message, &block)
	end

	synchronize do
	    if @queue.empty?
		empty_queue.signal
	    end
	end
    end

    def method_missing(*args, &block) # :nodoc:
	if Thread.current == @thread
	    super
	else
	    args << block
	    @queue.push args
	end
    end

    # Make the server object quit
    def quit!
	@thread.raise Quit
	@thread.join
    end

    def flush
        synchronize { empty_queue.wait_until { @queue.empty? } }
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
    @logger.formatter = lambda { |severity, time, progname, msg| "#{time.to_hms} #{progname} #{msg}\n" }

    extend Logger::Hierarchy
    extend Logger::Forward
end

