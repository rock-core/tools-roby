require 'fcntl'

module Roby
    module Tasks
        # This task class can be used to monitor the execution of an external
        # process. Among the useful features, it can redirect standard output and
        # error output to files.
        #
        # The events will act as follows:
        # * the start command starts the process per se. The event is emitted once
        #   exec() has been called with success
        # * the signaled event is emitted when the process dies because of a signal
        # * the failed event is emitted whenever the process exits with a nonzero
        #   status
        # * the success event is emitted when the process exits with a zero status
        # * the stop event is emitted when the process exits
        class ExternalProcess < Roby::Task
            ##
            # :attr_reader:
            # This task argument is an array whose first element is the executable
            # to start and the rest the arguments that need to be passed to it.
            #
            # It can also be set to a simple string, which is interpreted as the
            # executable name with no arguments.
            argument :command_line

            ##
            # :attr_reader:
            # The working directory. If not set, the current directory is used.
            argument :working_directory

            # Redirection specification. See #redirect_output
            attr_reader :redirection

            def initialize(arguments)
                arguments[:working_directory] ||= nil
                            arguments[:command_line] = [arguments[:command_line]] unless arguments[:command_line].kind_of?(Array)
                super(arguments)
            end

            class << self
                # The set of running ExternalProcess instances. It is a mapping
                # from the PID value to the instances.
                attr_reader :processes
            end
            @processes = Hash.new

            # Called by the SIGCHLD handler to announce that a particular process
            # has finished. It calls #dead!(result) in the context of the execution
            # thread, on the corresponding task
            def self.dead!(pid, result) # :nodoc:
                if task = processes[pid]
                    task.execution_engine.once { task.dead!(result) }
                end
            end

            # Called to announce that this task has been killed. +result+ is the
            # corresponding Process::Status object.
            def dead!(result)
                if !result
                    failed_event.emit
                elsif result.success?
                    success_event.emit
                elsif result.signaled?
                    signaled_event.emit(result)
                else
                    failed_event.emit(result)
                end
            end

            # This event gets emitted if the process died because of a signal
            event :signaled

            forward signaled: :failed

            ##
            # If set to a string, the process' standard output will be redirected to
            # the given file. The following replacement is done:
            # * '%p' is replaced by the process PID
            #
            # The last form (with nil argument) removes any redirection. A specific
            # redirection can also be disabled using the hash form:
            #   redirect_output stdout: nil
            #
            # :call-seq:
            #   redirect_output "file"
            #   redirect_output stdout: "file-out", stderr: "another-file"
            #   redirect_output nil
            #
            def redirect_output(args)
                if !args
                    @redirection = nil
                elsif args.respond_to? :to_str
                    @redirection = args.to_str
                else
                    args = validate_options args, stdout: nil, stderr: nil
                    if args[:stdout] == args[:stderr]
                        @redirection = args[:stdout].to_str
                    else
                        @redirection = Hash.new
                        @redirection[:stdout] = args[:stdout].to_str if args[:stdout]
                        @redirection[:stderr] = args[:stderr].to_str if args[:stderr]
                    end
                end
            end

            # The PID of the child process, or nil if the child process is not
            # running
            attr_reader :pid

            # Error codes between the child and the parent. Note that the error
            # codes must not be greater than 9
            # :stopdoc:
            KO_REDIRECTION  = 1
            KO_NO_SUCH_FILE = 2
            KO_EXEC         = 3
            # :startdoc:

            # Returns the file name based on the redirection pattern and the current
            # PID values. This is called in the child process before exec().
            def redirection_path(pattern) # :nodoc:
                pattern.gsub '%p', Process.pid.to_s
            end

            # Starts the child process
            def start_process # :nodoc:
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
                        Roby.log_exception_with_backtrace(e, Roby, :error)
                        w.write("#{KO_REDIRECTION}")
                        return
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
                        Roby.log_exception_with_backtrace(e, Roby, :error)
                        w.write("#{KO_EXEC}")
                    end
                end

                ExternalProcess.processes[pid] = self

                w.close
                begin
                    read, _ = select([r], nil, nil, 5)
                rescue IOError
                    Process.kill("SIGKILL", pid)
                    retry
                end

                if read && (control = r.read(1))
                    case Integer(control)
                    when KO_REDIRECTION
                        raise "could not start #{command_line.first}: cannot establish output redirections"
                    when KO_NO_SUCH_FILE
                        raise "could not start #{command_line.first}: provided command does not exist"
                    when KO_EXEC
                        raise "could not start #{command_line.first}: exec() call failed"
                    end
                end

                # This block is needed as there is a race condition between the fork
                # and the assignation to ExternalProcess.processes (which is
                # required for the SIGCHLD handler to work).
                begin
                    if Process.waitpid(pid, ::Process::WNOHANG)
                        if exit_status = $?
                            exit_status = exit_status.dup
                        end
                        execution_engine.once { dead!(pid, exit_status) }
                        return
                    end
                rescue Errno::ECHILD
                end

            rescue Exception => e
                ExternalProcess.processes.delete(pid)
                raise e
            end

            ##
            # :method: start!
            #
            # Starts the child process. Emits +start+ when the process is actually
            # started.
            event :start do |context|
                if working_directory
                    Dir.chdir(working_directory) do
                        start_process
                    end
                else
                    start_process
                end
                start_event.emit
            end

            # Kills the child process
            def kill(signo)
                Process.kill(signo, pid)
            end

            on :stop do |event|
                ExternalProcess.processes.delete(pid)
            end

            def self.handle_terminated_children(plan)
                begin
                    while pid = ::Process.wait(-1, ::Process::WNOHANG)
                        if exit_status = $?
                            exit_status = exit_status.dup
                        end
                        Roby.debug { "external process #{pid} terminated" }
                        Tasks::ExternalProcess.dead! pid, exit_status
                    end
                rescue Errno::ECHILD
                end
            end
        end

        Roby::ExecutionEngine.add_propagation_handler(
            description: 'ExternalProcess.handle_terminated_children',
            &ExternalProcess.method(:handle_terminated_children))
    end
end

