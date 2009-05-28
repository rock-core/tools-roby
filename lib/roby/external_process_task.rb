module Roby
    trap 'SIGCHLD' do
        begin
            pid = Process.waitpid
            ExternalProcessTask.dead! pid, $?.dup
        rescue Errno::ECHILD
        end
    end

    # This task class can be used to monitor the execution of an external
    # process. Among the useful features, it can redirect standard output and
    # error output to files.
    #
    # The events will act as follows:
    #  - the start command starts the process per se. The event is emitted once
    #    exec() has been called with success
    #  - the signaled event is emitted when the process dies because of a signal
    #  - the failed event is emitted whenever the process exits with a nonzero
    #    status
    #  - the success event is emitted when the process exits with a zero status
    #  - the stop event is emitted when the process exits
    class ExternalProcessTask < Roby::Task
        argument :command_line
        argument :working_directory

        # Redirection specification. See #redirect_output
        attr_reader :redirection

        def initialize(arguments)
            arguments[:working_directory] ||= nil
            super(arguments)
        end

        class << self
            attr_reader :processes
        end
        @processes = Hash.new

        def self.dead!(pid, result)
            task = processes[pid]
            return if !task

            engine = task.plan.engine
            if result.success?
                engine.once { task.emit :success }
            elsif result.signaled?
                engine.once { task.emit :signaled, result }
            else
                engine.once { task.emit :failed, result }
            end
        end

        # This event gets signaled if the process died because of a signal
        event :signaled
        forward :signaled => :failed

        # call-seq:
        #   redirect_output "file"
        #   redirect_output :stdout => "file-out", :stderr => "another-file"
        #   redirect_output nil
        #
        # If set to a string, the process' standard output will be redirected to
        # the given file. The following replacement is done:
        # * '%p' is replaced by the process PID
        #
        # The last form (with nil argument) removes any redirection. A specific
        # redirection can also be disabled using the hash form:
        #   redirect_output :stdout => nil
        #
        def redirect_output(args)
            if !args
                @redirection = nil
            elsif args.respond_to? :to_str
                @redirection = args.to_str
            else
                args = validate_options args, :stdout => nil, :stderr => nil
                if args[:stdout] == args[:stderr]
                    @redirection = args[:stdout].to_str
                else
                    @redirection = Hash.new
                    @redirection[:stdout] = args[:stdout].to_str if args[:stdout]
                    @redirection[:stderr] = args[:stderr].to_str if args[:stderr]
                end
            end
        end

        attr_reader :pid

        # Error codes between the child and the parent. Note that the error
        # codes must not be greater than 9
        KO_REDIRECTION  = 1
        KO_NO_SUCH_FILE = 2
        KO_EXEC         = 3

        def redirection_path(pattern)
            pattern.gsub '%p', Process.pid.to_s
        end

        def start_process
            # Open a pipe to monitor the child startup
            r, w = IO.pipe

            @pid = fork do
                # Open the redirection outputs
                stdout, stderr = nil
                begin
                    if redirection.respond_to?(:to_str)
                        stdout = stderr = File.open(redirection_path(redirection), "w")
                    elsif redirection
                        if stdout_file = redirection[:stdout]
                            stdout = File.open(redirection_path(stdout_file), "w")
                        end
                        if stderr_file = redirection[:stderr]
                            stderr = File.open(redirection_path(stderr_file), "w")
                        end
                    end
                rescue Exception => e
                    Roby.fatal e.message
                    w.write("#{KO_REDIRECTION}")
                end

                STDOUT.reopen(stdout) if stdout
                STDERR.reopen(stderr) if stderr

                r.close
                w.fcntl(Fcntl::F_SETFD, 1) # set close on exit
                ::Process.setpgrp
                begin
                    exec(*command_line)
                rescue Errno::ENOENT
                    w.write("#{KO_NO_SUCH_FILE}")
                rescue Exception => e
                    Roby.fatal e.message
                    w.write("#{KO_EXEC}")
                end
            end

            w.close
            control = Integer(r.read(1))
            if control == KO_REDIRECTION
                raise "could not start #{command_line.first}: cannot establish output redirections"
            elsif control == KO_NO_SUCH_FILE
                raise "could not start #{command_line.first}: provided command does not exist"
            elsif control == KO_EXEC
                raise "could not start #{command_line.first}: exec() call failed"
            end

            ExternalProcessTask.processes[pid] = self
        end

        event :start do |_|
            if working_directory
                Dir.chdir(working_directory) do
                    start_process
                end
            else
                start_process
            end
            emit :start
        end

        on :stop do |_|
            ExternalProcessTask.processes.delete(pid)
        end
    end
end

