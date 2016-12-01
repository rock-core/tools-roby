require 'stackprof'
require 'rbtrace'
require 'objspace'

module Roby
    module App
        # A command library that allows to control StackProf to profile a Roby
        # application
        class Debug < Roby::Interface::CommandLibrary
            # Start profiling
            #
            # @param [Boolean] one_shot automatically stop and save after cycles
            #   cycles, or one cycle if cycles is nil
            # @param [Integer] cycles a number of cycles after which the
            #   profiling is stopped and saved
            # @param [String] path the path into which results should be saved
            # @param [Symbol] mode one of :cpu, :wall or :object
            # @param [Integer] interval the sampling interval in microseconds
            #   for :cpu and :wall (defaults to 1000, that is 1ms), and the
            #   sampling rate in objects allocated for :object (defaults to 1)
            # @param [Boolean] raw whether the dump should include raw samples,
            #   needed e.g. for flamegraph generation
            def stackprof_start(one_shot: false, cycles: nil, mode: :cpu, interval: nil, raw: false)
                interval ||= if mode == :object then 1
                             else 1000
                             end
                StackProf.start(mode: mode, interval: interval, raw: raw)

                if one_shot || cycles
                    cycles ||= 1
                end

                if cycles
                    remaining_cycles = cycles
                    @cycle_counter_handler = execution_engine.at_cycle_begin do
                        remaining_cycles -= 1
                        if remaining_cycles == 0
                            execution_engine.at_cycle_end(once: true) do
                                remaining_cycles = cycles
                                StackProf.stop
                                path = stackprof_save
                                app.notify "profiling", 'INFO', "results saved in #{path} after #{cycles} cycles"
                                if one_shot
                                    app.notify "profiling", 'INFO', "stopped"
                                    execution_engine.remove_propagation_handler(@cycle_counter_handler)
                                else
                                    StackProf.start(mode: mode, interval: interval)
                                end
                            end
                        end
                    end
                    nil
                end
            end
            command 'stackprof_start', "start profiling",
                one_shot: "if true, saves and stops profiling after a certain number of cycles",
                cycles: "a number of cycles after which profiling results are saved, and if one_shot is true, profiling is stopped",
                path: "the directory under which the results should be saved",
                mode: "sampling mode, one of :cpu, :wall or :object",
                interval: "sampling interval. Either microseconds for :cpu and :wall (defaults to 1000, that is 1ms), or a number of objects for :object (defaults to one)",
                raw: "whether the profile should include raw samples, needed for e.g. flamegraph generation"

            # Stop profiling
            #
            # This does not save the results, call {#save} for this
            def stackprof_stop
                StackProf.stop
                if @cycle_counter_handler
                    execution_engine.remove_propagation_handler(@cycle_counter_handler)
                end
            end
            command 'stackprof_stop', "stops profiling. This does not save the results to disk, call #save explicitely for that"

            # @api private
            #
            # The filename that is used by default in {#save}. It is relative to
            # {#path}
            #
            # It is a time tag (down to the milliseconds) followed by the
            # sampling mode and a .dump extension
            def default_path(prefix)
                path = File.join(app.log_dir, 'debug')
                time = Time.now.strftime("%Y-%m-%d.%H%M%S.%3N")
                File.join(path, "#{prefix}-#{time}.dump")
            end

            # Save the current profiling results into the path given to {#start} 
            #
            # @param [String]
            def stackprof_save(path: default_path('stackprof-%s'))
                if results = StackProf.results
                    path = path % [results[:mode]]
                    FileUtils.mkdir_p(File.dirname(path))
                    File.open(path, 'wb') do |f|
                        f.write Marshal.dump(results)
                    end
                    path
                end
            end
            command 'stackprof_save', "saves the profiling results under the path specified in #start, by default is log_dir/stackprof"

            # Perform a memory dump
            def memdump(path: default_path('memdump'), run_gc: true)
                FileUtils.mkdir_p File.dirname(path)
                File.open(path, 'wb') do |io|
                    GC.start(full_mark: true, immediate_sweep: true) if run_gc
                    ObjectSpace.dump_all(output: io)
                end
                path
            end
            command 'memdump', 'save a dump of the whole memory space',
                path: "the file path where it should be saved, defaults to an automatically-generated file name in the debug/ subdirectory of the app's log directory"

            # Enable or disable allocation traces for {#memdump}
            def trace_allocations(enable)
                if enable
                    ObjectSpace.trace_object_allocations_start
                else
                    ObjectSpace.trace_object_allocations_stop
                    ObjectSpace.trace_object_allocations_clear
                end
            end
            command 'trace_allocations', 'whether location where allocations happen should be traced',
                enable: 'enable (true) or disable (false)'
        end
        Roby::Interface::Interface.subcommand 'debug', Debug, "debug-related commands"
    end
end

