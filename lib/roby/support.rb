# frozen_string_literal: true

require "facets/string/camelcase"
require "facets/string/snakecase"
require "facets/string/modulize"
require "facets/kernel/constant"
require "utilrb/time/to_hms"
require "utilrb/module/define_or_reuse"
require "utilrb/logger"
require "utilrb/marshal/load_with_missing_constants"

class IO
    def ask(question, default, output_io = STDOUT)
        output_io.print question
        output_io.flush
        loop do
            answer = readline.chomp.downcase

            if answer.empty?
                return default
            elsif answer == "y"
                return true
            elsif answer == "n"
                return false
            else
                output_io.print "\nInvalid answer, try again: "
                output_io.flush
            end
        end
    end
end

class Module
    def each_fullfilled_model
        return enum_for(__method__) unless block_given?

        yield self
    end
end

class Object
    def inspect
        guard = (Thread.current[:ROBY_SUPPORT_INSPECT_RECURSION_GUARD] ||= {})
        guard.compare_by_identity
        return "..." if guard.key?(self)

        begin
            guard[self] = self
            to_s
        ensure
            guard.delete(self)
        end
    end
end

class Set
    def inspect
        to_s
    end

    unless method_defined?(:intersect?)
        def intersect?(set)
            raise ArgumentError, "value must be a set" unless set.kind_of?(Set)

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
        each { return false } # rubocop:disable Lint/UnreachableLoop
        true
    end
end

class Thread
    def send_to(object, name, *args, &prc)
        if Thread.current == self
            object.send(name, *args, &prc)
        else
            @msg_queue ||= Queue.new
            @msg_queue << [object, name, args, prc]
        end
    end

    def process_events
        @msg_queue ||= Queue.new
        loop do
            object, name, args, block = *@msg_queue.deq(true)
            object.send(name, *args, &block)
        end
    rescue ThreadError # rubocop:disable Lint/HandleExceptions
    end
end

module Roby
    def self.format_time(time, format = "hms")
        case format
        when "sec"
            time.to_f.to_s
        when "hms"
            time.strftime("%H:%M:%S.%3N")
        else
            time.strftime(format)
        end
    end

    # Helper to handle Ruby 2.7 behavior when mixing symbols and non-symbols in
    # "last arg used as keyword hash"
    #
    # Under Ruby 2.7, the call
    #
    #   def provides(*ary, **kw)
    #   end
    #   provides "some" => "mapping", as: "name"
    #
    # Will pass all arguments to the keywords splat. This method extracts them
    # again, adding the resulting hash to the ary argument if there are any,
    # and doing nothing otherwise (for backward and forward compatibility)
    def self.sanitize_keywords_to_array(array, keywords)
        hash = sanitize_keywords(keywords)
        array << hash unless hash.empty?
    end

    # Helper to handle Ruby 2.7 behavior when mixing symbols and non-symbols in
    # "last arg used as keyword hash"
    #
    # Under Ruby 2.7, the call
    #
    #   def provides(hash = {}, **kw)
    #   end
    #   provides "some" => "mapping", as: "name"
    #
    # Will pass all arguments to the keywords splat. This method extracts them
    # again, merging resulting hash into the hash argument if there are any,
    # and doing nothing otherwise (for backward and forward compatibility)
    def self.sanitize_keywords_to_hash(hash, keywords)
        extracted = sanitize_keywords(keywords)
        hash.merge!(extracted) unless extracted.empty?
    end

    def self.sanitize_keywords(keywords)
        hash = {}
        keywords.delete_if do |k, v|
            unless k.kind_of?(Symbol)
                hash[k] = v
                true
            end
        end
        hash
    end

    logger_m = Logger::Root("Roby", Logger::WARN) do |_severity, time, progname, msg|
        "#{Roby.format_time(time)} (#{progname}) #{msg}\n"
    end
    extend logger_m

    class << self
        attr_accessor :enable_deprecation_warnings, :deprecation_warnings_are_errors
    end
    @enable_deprecation_warnings = true
    @deprecation_warnings_are_errors = (ENV["ROBY_ALL_DEPRECATIONS_ARE_ERRORS"] == "1")

    def self.warn_deprecated(msg, caller_depth = 1)
        if deprecation_warnings_are_errors
            error_deprecated(msg, caller_depth)
        elsif enable_deprecation_warnings
            Roby.warn "Deprecation Warning: #{msg} " \
                      "at #{caller[1, caller_depth].join("\n")}"
        end
    end

    def self.error_deprecated(msg, caller_depth = 1)
        Roby.fatal "Deprecation Error: #{msg} at #{caller[1, caller_depth].join("\n")}"
        raise NotImplementedError
    end

    # Cross-platform way of finding a file in the $PATH.
    #
    #   which('ruby') #=> /usr/bin/ruby
    def self.find_in_path(cmd)
        return cmd if cmd =~ (/#{File::SEPARATOR}/) && File.file?(cmd)

        exts = ENV["PATHEXT"] ? ENV["PATHEXT"].split(";") : [""]
        ENV["PATH"].split(File::PATH_SEPARATOR).each do |path|
            exts.each do |ext|
                exe = File.join(path, "#{cmd}#{ext}")
                return exe if File.file?(exe)
            end
        end
        nil
    end

    # Cross-platform way of finding an executable in the $PATH.
    #
    #   which('ruby') #=> /usr/bin/ruby
    def self.which(cmd)
        return unless (path = find_in_path(cmd))

        path if File.executable?(path)
    end
end
