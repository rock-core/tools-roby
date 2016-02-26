module Roby
    module DRoby
        # Object that acts as an observer for ExecutablePlan, handling
        # the droby marshalling/demarshalling. Dumping to IO is delegated to
        # {#logfile}, a separate object that must provide a #dump method the way
        # {Logfile::Writer} does
        class EventLogger
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
            def initialize(logfile, queue_size: 50)
                @stats_mode = false
                @logfile = logfile
                @object_manager = ObjectManager.new(nil)
                @marshal = Marshal.new(object_manager, nil)
                @current_cycle = Array.new
                @sync = true
                @dump_time = 0
                if queue_size > 0
                    @dump_queue  = SizedQueue.new(queue_size)
                    @dump_thread = Thread.new(&method(:dump_loop))
                end
            end

            def log_queue_size
                if threaded? then @dump_queue.size
                else 0
                end
            end

            def threaded?
                !!@dump_queue
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
                dump(:cycle_end, Time.now, [Hash.new])
                if threaded?
                    @dump_queue.push nil
                    @dump_thread.join
                end

            ensure
                logfile.close
            end

            # Dump one log message
            def dump(m, time, args)
                start = Time.now
                if stats_mode? && m == :cycle_end
                    current_cycle << m << time.tv_sec << time.tv_usec << args
                else
                    if m == :merged_plan
                        plan_id, merged_plan = *args

                        merged_plan.known_tasks.each do |t|
                            object_manager.register_object(t)
                        end
                        merged_plan.free_events.each do |e|
                            object_manager.register_object(e)
                        end
                        merged_plan.task_events.each do |e|
                            object_manager.register_object(e)
                        end
                        args = [plan_id, merged_plan.droby_dump(marshal)]
                    elsif m == :finalized_task
                        task = args[1]
                        args = marshal.dump(args)
                        object_manager.deregister_object(task)
                    elsif m == :finalized_event
                        event = args[1]
                        args = marshal.dump(args)
                        object_manager.deregister_object(event)
                    else
                        args = marshal.dump(args)
                    end

                    current_cycle << m << time.tv_sec << time.tv_usec << args
                end

                if m == :cycle_end
                    if threaded?
                        if !@dump_thread.alive?
                            @dump_thread.value
                        end

                        @dump_queue << current_cycle
                        @current_cycle = Array.new
                    else
                        logfile.dump(current_cycle)
                        if sync?
                            logfile.flush
                        end
                        current_cycle.clear
                    end
                end

            ensure @dump_time += (Time.now - start)
            end

            # Main dump loop if the logger is threaded
            def dump_loop
                while cycle = @dump_queue.pop
                    logfile.dump(cycle)
                    if sync?
                        logfile.flush
                    end
                end
            end
        end
    end
end

