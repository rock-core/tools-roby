# frozen_string_literal: true

module Roby
    module EventLogging
        # Object that acts as an observer for ExecutablePlan, handling
        # the droby marshalling/demarshalling. Dumping to IO is delegated to
        # {#logfile}, a separate object that must provide a #dump method the way
        # {Logfile::Writer} does
        class DRobyEventLogger
            # The object that will be given the cycles to be written
            #
            # @return [#dump]
            attr_reader :logfile

            # The set of events for the current cycle. This is dumped only
            # when the +cycle_end+ event is received
            attr_reader :current_cycle

            # The object manager
            #
            # @return [DRoby::ObjectManager]
            attr_reader :object_manager

            # The marshalling object
            #
            # @return [DRoby::Marshal]
            attr_reader :marshal

            # The time spent logging so far
            attr_reader :dump_time

            # @!method log_timepoints?
            # @!method log_timepoints=(flag)
            #
            # Controls whether the logger should save generated timepoints
            # or ignore them. This makes the logs bigger by an order of
            # magnitude (at least)
            attr_predicate :log_timepoints, true

            # @!method stats_mode?
            # @!method stats_mode=(flag)
            #
            # Controls whether the logger should only dump statistics, or the
            # full set of plan events
            attr_predicate :stats_mode, true

            # @!method sync?
            # @!method sync=(flag)
            #
            # Controls whether log data should be flushed on disk after each
            # cycle. It is set by default. Disable for improved performance
            # if the data will not be displayed live
            #
            # {Roby::Application} disables it by default if the log server is
            # disabled
            attr_predicate :sync?, true

            # @param [#dump] marshal the object that transforms the arguments
            #   into droby-compatible objects
            # @param [Integer] queue_size if non-zero, the access to I/O will
            #   be done in a separate thread, and this parameter is the maximum
            #   amount of cycles that can be queued in a backlog until the
            #   main thread waits on the logger
            def initialize(logfile, queue_size: 50, log_timepoints: false)
                @stats_mode = false
                @logfile = logfile
                @object_manager = DRoby::ObjectManager.new(nil)
                @marshal = DRoby::Marshal.new(object_manager, nil)
                @current_cycle = []
                @sync = true
                @dump_time = 0
                @mutex = Mutex.new
                @log_timepoints = log_timepoints

                return unless queue_size > 0

                @dump_queue  = SizedQueue.new(queue_size)
                @dump_thread = Thread.new(&method(:dump_loop))
            end

            def register_executable_plan(plan)
                dump(:register_executable_plan, Time.now, [plan.droby_id])
            end

            def synchronize(&block)
                @mutex.synchronize(&block)
            end

            def log_queue_size
                if threaded? then @dump_queue.size
                else
                    0
                end
            end

            def threaded?
                @dump_queue
            end

            def flush
                if threaded?
                    @dump_queue.push nil
                    @dump_thread.join
                    logfile.flush
                    @dump_thread = Thread.new(&method(:dump_loop))
                else
                    logfile.flush
                end
            end

            # Close this logger, flushing the remaining data to I/O
            def close
                if threaded?
                    @dump_queue.push nil
                    @dump_thread.join
                end
            ensure
                logfile.close
            end

            def append_message(name, time, args)
                args =
                    case name
                    when :merged_plan
                        process_merged_plan(args)
                    when :finalized_task
                        process_finalized_task(args)
                    when :finalized_event
                        process_finalized_event(args)
                    else
                        marshal.dump(args)
                    end

                @current_cycle << name << time.tv_sec << time.tv_usec << args
            end

            def process_merged_plan(args)
                plan_id, merged_plan = *args

                merged_plan.tasks.each do |t|
                    object_manager.register_object(t)
                end
                merged_plan.free_events.each do |e|
                    object_manager.register_object(e)
                end
                merged_plan.task_events.each do |e|
                    object_manager.register_object(e)
                end
                [plan_id, merged_plan.droby_dump(marshal)]
            end

            def process_finalized_task(args)
                task = args[1]
                args = marshal.dump(args)
                object_manager.deregister_object(task)
                args
            end

            def process_finalized_event(args)
                task = args[1]
                args = marshal.dump(args)
                object_manager.deregister_object(task)
                args
            end

            def dump_timepoint(event, time, args)
                return if stats_mode? || !log_timepoints?

                synchronize do
                    @current_cycle << event << time.tv_sec << time.tv_usec << args
                end
            end

            # Dump one log message
            def dump(name, time, args)
                return if stats_mode?

                start = Time.now
                synchronize do
                    append_message(name, time, args)
                end
            ensure @dump_time += (Time.now - start)
            end

            def flush_cycle(*last_message)
                start = Time.now
                if threaded?
                    @dump_thread.value unless @dump_thread.alive?

                    synchronize do
                        append_message(*last_message)
                        @dump_queue << @current_cycle
                        @current_cycle = []
                    end
                else
                    append_message(*last_message)
                    logfile.dump(@current_cycle)
                    logfile.flush if sync?
                    @current_cycle.clear
                end
            ensure @dump_time += (Time.now - start)
            end

            # Main dump loop if the logger is threaded
            def dump_loop
                while (cycle = @dump_queue.pop)
                    logfile.dump(cycle)
                    logfile.flush if sync?
                end
            end
        end
    end

    module DRoby
        # Backward-compatible reference to EventLogging::DRobyEventLogger
        EventLogger = Roby::EventLogging::DRobyEventLogger
    end
end
