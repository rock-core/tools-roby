# frozen_string_literal: true

require "stackprof"

module Roby
    module EventLogging
        # A simple event logger that displays a textual representation of the events
        # on plain I/O (e.g. log file or stdout)
        class StackProfEventManager
            # The stackprof mode
            #
            # @return [Symbol] stackprof sampling mode. At the time of this writing,
            #   can be one of :wall, :cpu or :object
            attr_accessor :mode

            # Whether stackprof saves raw samples
            #
            # They are needed for post-processing like e.g. flamegraph. The default is
            # false
            #
            # @return [Boolean]
            attr_accessor :raw

            # Quit the application when the profile data has been dumped
            #
            # @return [Boolean]
            attr_accessor :quit

            # How many start/stop cycles to ignore before we start profiling
            #
            # @return [Integer,nil] the configured skip cycles
            attr_accessor :skip

            # How many start/stop cycles until we dump the results
            #
            # @return [Integer,nil] the count, or nil to dump on close
            attr_accessor :count

            # How many start/stop cycles until we dump the results
            #
            # @return [Integer,nil] the count, or nil to dump on close
            attr_accessor :results_path

            def initialize
                @results_path = "/tmp/roby-stackprof-#{Process.pid}"
                @skip = 0
                @count = nil
                @remaining_count = nil
                @remaining_skip = nil
                @mode = :cpu
                @raw = false
                @dumped_results = false
                @quit = false
            end

            # Start profiling whenever a timepoint name matches the given matcher
            #
            # @param [#===] matcher the matcher object. It replaces an existing object
            #   (if there was one)
            def start_on(matcher)
                @start_matcher = matcher
            end

            # Stop profiling whenever a timepoint name matches the given matcher
            #
            # @param [#===] matcher the matcher object. It replaces an existing object
            #   (if there was one)
            def stop_on(matcher)
                @stop_matcher = matcher
            end

            # @api private
            #
            # Start profiling
            def stackprof_handle_start_timepoint(timepoint_name)
                return if StackProf.running?
                return if @remaining_count && @remaining_count <= 0

                @remaining_skip ||= @skip
                if @remaining_skip > 0
                    @remaining_skip -= 1
                    return
                end

                Robot.info "stackprof: started on timepoint #{timepoint_name}"
                StackProf.start(mode: @mode.to_sym, raw: @raw)
            end

            # @api private
            #
            # Handle the reception of a stop timepoint while stackprof was running
            def stackprof_handle_stop_timepoint(timepoint_name)
                return unless StackProf.running?

                Robot.info "stackprof: stopped on timepoint #{timepoint_name}"
                StackProf.stop

                @remaining_count ||= @count

                if @remaining_count > 0
                    @remaining_count -= 1
                    Robot.info "stackprof: #{@count - @remaining_count} regions profiled"
                    return unless @remaining_count == 0
                end

                stackprof_dump_results
                Roby.app.quit if @quit
            end

            def stackprof_dump_results
                StackProf.results(results_path)
                Robot.info "stackprof: results dumped on #{results_path}"
            end

            def log_timepoints?
                true
            end

            def dump(name, time, args); end

            TIMEPOINT_KIND_START = %I[timepoint timepoint_group_start].freeze
            TIMEPOINT_KIND_END = %I[timepoint timepoint_group_end].freeze

            def dump_timepoint(kind, _time, args)
                tp_name = args[2]

                if TIMEPOINT_KIND_START.include?(kind) && (@start_matcher === tp_name)
                    stackprof_handle_start_timepoint(tp_name)
                elsif TIMEPOINT_KIND_END.include?(kind) && (@stop_matcher === tp_name)
                    stackprof_handle_stop_timepoint(tp_name)
                end

                nil
            end

            def close
                return unless StackProf.running?

                StackProf.stop
                stackprof_dump_results
            end

            def log_queue_size
                0
            end

            def dump_time
                0
            end

            def flush_cycle(name, *args); end
        end
    end
end
