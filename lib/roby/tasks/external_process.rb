require 'fcntl'

module Roby
    module Tasks
        # This task class can be used to monitor the execution of an external
        # process. Among the useful features, it can redirect standard output and
        # error output to files.
        #
        # The events will act as follows:
        # * the start command starts the process per se. The event is emitted once
        #   the process has been spawned with success
        # * the signaled event is emitted when the process dies because of a signal.
        #   The event's context is the Process::Status object.
        # * the failed event is emitted whenever the process exits with a nonzero
        #   status. The event's context is the Process::Status object.
        # * the success event is emitted when the process exits with a zero status
        # * the stop event is emitted when the process exits, regardless of how
        #
        # The task by default is not interruptible, because there is no good
        # common way to gracefully terminate an external program. To e.g. use
        # signals, one would need to explicitely make the :stop command send a
        # signal to {#pid} and let ExternalProcess' signal handling do the rest.
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
            argument :working_directory, default: nil

            # Event emitted if the process died because of a signal
            #
            # @param [Process::Status] the process status
            event :signaled

            forward :signaled => :failed

            # The PID of the child process, or nil if the child process is not
            # running
            attr_reader :pid

            def initialize(arguments = Hash.new)
                if arg = arguments[:command_line]
                    arguments[:command_line] = [arg] if !arg.kind_of?(Array)
                end
                @pid = nil
                @buffer = nil
                @redirection = Hash.new
                super(arguments)
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
            def redirect_output(common = nil, stdout: nil, stderr: nil)
                if @pid
                    raise RuntimeError, "cannot change redirection after task start"
                elsif common
                    stdout = stderr = common
                end

                @redirection = Hash.new
                if stdout
                    @redirection[:stdout] = 
                        if [:pipe, :close].include?(stdout) then stdout
                        else stdout.to_str
                        end
                end
                if stderr
                    @redirection[:stderr] = 
                        if [:pipe, :close].include?(stderr) then stderr
                        else stderr.to_str
                        end
                end
            end

            # @api privater
            #
            # Handle redirection for a single stream (out or err)
            def create_redirection(redir_target)
                if !redir_target
                    return [], nil
                elsif redir_target == :close
                    return [], :close
                elsif redir_target == :pipe
                    pipe, io = IO.pipe
                    return [[:close, io]], io, pipe, String.new
                elsif redir_target !~ /%p/
                    # Assume no replacement in redirection, just open the file
                    if redir_target[0, 1] == '+'
                        io = File.open(redir_target[1..-1], 'a')
                    else
                        io = File.open(redir_target, 'w')
                    end
                    return [[:close, io]], io
                else
                    io = open_redirection(working_directory) 
                    return [[redir_target, io]], io
                end
            end

            # @api private
            #
            # Setup redirections pre-spawn
            def handle_redirection
                if !@redirection[:stdout] && !@redirection[:stderr]
                    return [], Hash.new
                elsif (@redirection[:stdout] == @redirection[:stderr]) && ![:pipe, :close].include?(@redirection[:stdout])
                    io = open_redirection(working_directory) 
                    return [[@redirection[:stdout], io]], Hash[out: io, err: io]
                end

                out_open, out_io, @out_pipe, @out_buffer =
                    create_redirection(@redirection[:stdout])
                err_open, err_io, @err_pipe, @err_buffer =
                    create_redirection(@redirection[:stderr])

                if @out_buffer || @err_buffer
                    @read_buffer = String.new
                end

                spawn_options = Hash.new
                spawn_options[:out] = out_io if out_io
                spawn_options[:err] = err_io if err_io
                return (out_open + err_open), spawn_options
            end

            ##
            # :method: start!
            #
            # Starts the child process. Emits +start+ when the process is actually
            # started.
            event :start do |context|
                working_directory = (self.working_directory || Dir.pwd)
                options = Hash[pgroup: 0, chdir: working_directory]

                opened_ios, spawn_options = handle_redirection

                @pid = Process.spawn *command_line, **spawn_options
                opened_ios.each do |pattern, io|
                    if pattern == :close
                        io.close
                    else
                        FileUtils.mv io.path, File.join(working_directory, redirection_path(pattern, @pid))
                    end
                end

                start_event.emit
            end

            # @api private
            #
            # Returns the file name based on the redirection pattern and the current
            # PID value.
            def redirection_path(pattern, pid) # :nodoc:
                pattern.gsub '%p', pid.to_s
            end

            # @api private
            #
            # Open the output file for redirection, before spawning
            def open_redirection(dir)
                Dir::Tmpname.create 'roby-external-process', dir do |path, _|
                    return File.open(path, 'w+')
                end
            end

            # Kills the child process
            #
            # @param [String,Integer] signo the signal name or number, as
            #   accepted by Process#kill
            def kill(signo)
                Process.kill(signo, pid)
            end

            # @api private
            #
            # Read a given pipe, when an output is redirected to pipe
            def read_pipe(pipe, buffer)
                received = false
                while true
                    pipe.read_nonblock 1024, @read_buffer
                    received = true
                    buffer.concat(@read_buffer)
                end
            rescue EOFError
                if received
                    return true, buffer.dup
                end
            rescue IO::WaitReadable
                if received
                    return false, buffer.dup
                end
            end

            # Method called when data is received on an intercepted stdout
            #
            # Intercept stdout by calling redirect_output(stdout: :pipe)
            def stdout_received(data)
            end

            # Method called when data is received on an intercepted stderr
            #
            # Intercept stdout by calling redirect_output(stderr: :pipe)
            def stderr_received(data)
            end

            def read_pipes
                if @out_pipe
                    eos, data = read_pipe(@out_pipe, @out_buffer)
                    if eos
                        @out_pipe = nil
                    end
                    if data
                        stdout_received(data)
                    end
                end
                if @err_pipe
                    eos, data = read_pipe(@err_pipe, @err_buffer)
                    if eos
                        @err_pipe = nil
                    end
                    if data
                        stderr_received(data)
                    end
                end
            end

            poll do
                read_pipes
                pid, exit_status = ::Process.waitpid2(self.pid, ::Process::WNOHANG)
                if pid
                    dead!(exit_status)
                end
            end

            on :stop do |event|
                read_pipes
            end
        end
    end
end

