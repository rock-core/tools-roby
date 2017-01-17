require 'thread'
require 'facets/string/camelcase'
require 'facets/string/snakecase'
require 'facets/string/modulize'
require 'facets/kernel/constant'
require 'utilrb/time/to_hms'
require 'utilrb/module/define_or_reuse'
require 'utilrb/logger'
require 'utilrb/marshal/load_with_missing_constants'

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

class Object
    def inspect
        guard = (Thread.current[:ROBY_SUPPORT_INSPECT_RECURSION_GUARD] ||= Hash.new)
        guard.compare_by_identity
        if guard.has_key?(self)
            return "..."
        else
            begin
                guard[self] = self
                to_s
            ensure
                guard.delete(self)
            end
        end
    end
end

class Set
    def inspect
        to_s
    end

    if !method_defined?(:intersect?)
        def intersect?(set)
            set.is_a?(Set) or raise ArgumentError, "value must be a set"
            if size < set.size
                any? { |o| set.include?(o) }
            else
                set.any? { |o| include?(o) }
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

