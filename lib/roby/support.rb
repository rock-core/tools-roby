require 'thread'
require 'roby/config'
require 'facets/string/camelcase'
require 'facets/string/snakecase'
require 'facets/string/modulize'
require 'facets/kernel/constant'
require 'utilrb/enumerable'
require 'utilrb/time/to_hms'
require 'utilrb/module/cached_enum'
require 'utilrb/module/define_or_reuse'
require 'utilrb/logger'
require 'utilrb/gc/force'
require 'utilrb/hash/to_sym_keys'
require 'utilrb/array/to_s'
require 'utilrb/hash/to_s'
require 'utilrb/set/to_s'
require 'utilrb/marshal/load_with_missing_constants'
require 'drb'

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

class Set
    def difference!(other_set)
        substract(other_set)
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

if DRb.respond_to?(:uri)
    # Workaround issue on new DRb versions. The problem was that some objects
    # were not properly recognized as being local
    module DRb
        def self.here?(uri)
            (DRb.uri rescue nil) == uri
        end
    end
end

module Roby
    def self.format_time(time, format = 'hms')
        if format == 'sec'
            time.to_f.to_s
        elsif format == 'hms'
            "#{time.strftime('%H:%M:%S')}.#{'%.03i' % [time.tv_usec / 1000]}"
        else
            "#{time.strftime(format)}"
        end
    end

    extend Logger::Root('Roby', Logger::WARN) { |severity, time, progname, msg| "#{Roby.format_time(time)} (#{progname}) #{msg}\n" }

    class Pool < Queue
	def initialize(klass)
	    @klass = klass
            super()
	end

	def pop
	    value = super(true) rescue nil
	    value || @klass.new
	end
    end

    @mutexes = Pool.new(Mutex)
    @condition_variables = Pool.new(ConditionVariable)
    class << self
        # A pool of mutexes (as a Queue)
        attr_reader :mutexes
        # A pool of condition variables (as a Queue)
        attr_reader :condition_variables
    end

    # call-seq:
    #   condition_variable => cv
    #   condition_variable(true) => cv, mutex
    #   condition_variable { |cv| ... } => value returned by the block
    #   condition_variable(true) { |cv, mutex| ... } => value returned by the block
    #
    # Get a condition variable object from the Roby.condition_variables
    # pool and, if mutex is not true, a Mutex object
    #
    # If a block is given, the two objects are yield and returned into the
    # pool after the block has returned. In that case, the method returns
    # the value returned by the block
    def self.condition_variable(mutex = false)
        cv = condition_variables.pop

        if block_given?
            begin
                if mutex
                    mt = mutexes.pop
                    yield(cv, mt)
                else
                    yield(cv)
                end

            ensure
                return_condition_variable(cv, mt)
            end
        else
            if mutex
                return cv, mutexes.pop
            else
                return cv
            end
        end
    end

    # Returns a ConditionVariable and optionally a Mutex into the
    # Roby.condition_variables and Roby.mutexes pools
    def self.return_condition_variable(cv, mutex = nil)
        condition_variables.push cv
        if mutex
            mutexes.push mutex
        end
        nil
    end

    @global_lock = Mutex.new
    class << self
        # This Mutex object is locked during the event propagation loop, and
        # unlock while this loop is sleeping. It is used to wait for the
        # availability of the main plan.
        attr_reader :global_lock
    end

    def self.taken_global_lock?; Thread.current[:global_lock_taken] end

    # Implements a recursive behaviour on Roby.mutex
    def self.synchronize
        if Thread.current[:global_lock_taken]
            yield
        else
            global_lock.lock
            begin
                Thread.current[:global_lock_taken] = true
                yield
            ensure
                Thread.current[:global_lock_taken] = false
                begin
                    global_lock.unlock
                rescue ThreadError
                end
            end
        end
    end

    class << self
        attr_accessor :enable_deprecation_warnings
    end
    @enable_deprecation_warnings = true

    def self.warn_deprecated(msg, caller_depth = 1)
        if enable_deprecation_warnings
            Roby.warn "Deprecation Warning: #{msg} at #{caller[1, caller_depth].join("\n")}"
        end
    end

    def self.error_deprecated(msg, caller_depth = 1)
        Roby.fatal "Deprecation Error: #{msg} at #{caller[1, caller_depth].join("\n")}"
        raise NotImplementedError
    end
end

