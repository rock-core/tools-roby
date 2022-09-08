# frozen_string_literal: true

require "fcntl"

module Roby
    module Tasks
        # This task class can be used to monitor the execution of an external
        # process.
        #
        # Importantly, the task by default is not interruptible, because there
        # is no good common way to gracefully terminate an external program.  To
        # use the common way to stop the task with a signal, use
        # {.interruptible_with_signal} instead of {.new} to create a task instance, which
        # will set it up by default for you
        #
        # Among the useful features, it can redirect standard output and
        # error output to files.
        #
        # The events will act as follows:
        #
        # * the start command starts the process per se. The event is emitted once
        #   the process has been spawned with success
        # * the signaled event is emitted when the process dies because of a signal.
        #   The event's context is the Process::Status object.
        # * the failed event is emitted whenever the process exits with a nonzero
        #   status. The event's context is the Process::Status object.
        # * the success event is emitted when the process exits with a zero status
        # * the stop event is emitted when the process exits, regardless of how
        class ExternalProcess < Roby::Task
            # @!attribute [rw] command_line
            #   @return [Array,String] If an array, its first element is the
            #   executable to start and the rest the arguments that need to be
            #   passed to it. If a string, it is interpreted as the executable
            #   name with no arguments.
            argument :command_line

            # @!attribute [rw] working_directory
            #   The working directory. If not set, the current directory is used.
            argument :working_directory, default: nil

            # @!attribute [rw] stub_in_roby_simulation_mode
            #   Controls whether the task should actually start the subprocess
            #   or not. If `nil`, the behavior is controlled by
            #   {ExternalProcess.stub_in_roby_simulation_mode}
            argument :stub_subprocess, default: nil

            class << self
                # Sets the default behavior of all ExternalProcess tasks regarding
                # roby simulation mode (i.e. roby test)
                #
                # If true, tasks will not actually start the subprocess, but will check
                # that it is in PATH and executable. If false, the subprocess is started.
                # The flag can be overriden on a per-task basis by setting the
                # stub_in_roby_simulation_mode argument to either `true` or
                # `false`. Use `nil` to use the default
                #
                # The default is false for backward compatibility reasons
                #
                # @see {.stub_in_roby_simulation_mode?}
                #   {ExternalProcess#stub_in_roby_simulation_mode}
                attr_writer :stub_in_roby_simulation_mode

                # @see {.stub_in_roby_simulation_mode=}
                def stub_in_roby_simulation_mode?
                    @stub_in_roby_simulation_mode
                end

                @stub_in_roby_simulation_mode = false
            end

            # Event emitted if the process died because of a signal
            #
            # It carries the process signal as Process::Status
            event :signaled

            forward signaled: :failed

            # The PID of the child process, or nil if the child process is not
            # running
            attr_reader :pid

            def initialize(command_line: nil, **arguments)
                command_line = Array(command_line) if command_line

                @pid = nil
                @buffer = nil
                @redirection = {}

                if arguments[:stub_subprocess].nil?
                    arguments[:stub_subprocess] =
                        Roby.app.simulation? &&
                        ExternalProcess.stub_in_roby_simulation_mode?
                end
                super(command_line: command_line, **arguments)
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

            # @overload redirect_output(common)
            # @overload redirect_output(stdout: nil, stderr: nil)
            #   Redirect either stdout and stderr. The redirection target can either be
            #   a string, which is interpreted as a path, or one of :pipe and :close.
            #
            #   If redirecting to a string, %p is replaced by the process actual
            #   PID. Both can be redirected to the same output file
            #
            #   The special value :pipe shall be used to make the task read the
            #   process output and call {#stdout_received} (resp.
            #   {#stderr_received}) with it. :close will make the task close
            #   this output
            #
            #   Pass `nil` to not redirect this particular output. Calling the method
            #   with a single argument applies this redirection to both outputs.
            #
            def redirect_output(common = nil, stdout: nil, stderr: nil)
                raise "cannot change redirection after task start" if @pid

                stdout = stderr = common if common

                @redirection = {
                    stdout: normalize_redirection_mode(common || stdout),
                    stderr: normalize_redirection_mode(common || stderr)
                }
            end

            # @api private
            #
            # Normalize the redirection target argument of {#redirect_output}
            def normalize_redirection_mode(mode)
                return unless mode

                if %i[pipe close].include?(mode)
                    mode
                else
                    mode.to_str
                end
            end

            # @api privater
            #
            # Handle redirection for a single stream (out or err)
            def create_redirection(redir_target)
                if !redir_target
                    [[], nil]
                elsif redir_target == :close
                    [[], :close]
                elsif redir_target == :pipe
                    pipe, io = IO.pipe
                    [[[:close, io]], io, pipe, "".dup]
                elsif redir_target !~ /%p/
                    # Assume no replacement in redirection, just open the file
                    io =
                        if redir_target[0, 1] == "+"
                            File.open(redir_target[1..-1], "a")
                        else
                            File.open(redir_target, "w")
                        end
                    [[[:close, io]], io]
                else
                    dir = File.dirname(File.expand_path(redir_target, working_directory))
                    io = open_redirection(dir)
                    [[[redir_target, io]], io]
                end
            end

            # @api private
            #
            # Setup redirections pre-spawn
            def handle_redirection
                return [], {} if !@redirection[:stdout] && !@redirection[:stderr]

                if (@redirection[:stdout] == @redirection[:stderr]) &&
                   !%i[pipe close].include?(@redirection[:stdout])
                    redir_target = @redirection[:stdout]
                    dir = File.dirname(File.expand_path(redir_target, working_directory))
                    io = open_redirection(dir)
                    return [[@redirection[:stdout], io]], Hash[out: io, err: io]
                end

                out_open, out_io, @out_pipe, @out_buffer =
                    create_redirection(@redirection[:stdout])
                err_open, err_io, @err_pipe, @err_buffer =
                    create_redirection(@redirection[:stderr])

                @read_buffer = "".dup if @out_buffer || @err_buffer

                spawn_options = {}
                spawn_options[:out] = out_io if out_io
                spawn_options[:err] = err_io if err_io
                [(out_open + err_open), spawn_options]
            end

            ##
            # :method: start!
            #
            # Starts the child process. Emits +start+ when the process is actually
            # started.
            event :start do |_|
                working_directory = (self.working_directory || Dir.pwd)
                opened_ios, spawn_options = handle_redirection

                if stub_subprocess
                    @pid = rand(65_535)
                    validate_program(command_line[0])
                else
                    @pid = Process.spawn(
                        *command_line, chdir: working_directory, **spawn_options
                    )
                end

                opened_ios.each do |pattern, io|
                    if pattern != :close
                        target_path = File.expand_path(
                            redirection_path(pattern, @pid), working_directory
                        )
                        FileUtils.mv io.path, target_path
                    end
                    io.close
                end

                start_event.emit
            end

            # @api private
            #
            # Emulates error handling of Process.spawn when stub_subprocess is set
            def validate_program(cmd)
                raise Errno::ENOENT, cmd unless (absolute = Roby.find_in_path(cmd))
                raise Errno::EACCES, cmd unless File.executable?(absolute)

                nil
            end

            # @api private
            #
            # Returns the file name based on the redirection pattern and the current
            # PID value.
            def redirection_path(pattern, pid) # :nodoc:
                pattern.gsub "%p", pid.to_s
            end

            # @api private
            #
            # Open the output file for redirection, before spawning
            def open_redirection(dir)
                Dir::Tmpname.create "roby-external-process", dir do |path, _|
                    return File.open(path, "w+")
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
                loop do
                    pipe.read_nonblock 1024, @read_buffer
                    received = true
                    buffer.concat(@read_buffer)
                end
            rescue EOFError
                pipe.close
                [true, buffer.dup]
            rescue IO::WaitReadable
                [false, buffer.dup] if received
            end

            # Method called when data is received on an intercepted stdout
            #
            # Intercept stdout by calling redirect_output(stdout: :pipe)
            def stdout_received(data); end

            # Method called when data is received on an intercepted stderr
            #
            # Intercept stdout by calling redirect_output(stderr: :pipe)
            def stderr_received(data); end

            def read_pipes
                if @out_pipe
                    eos, data = read_pipe(@out_pipe, @out_buffer)
                    @out_pipe = nil if eos
                    stdout_received(data) if data
                    @out_buffer.clear
                end

                if @err_pipe
                    eos, data = read_pipe(@err_pipe, @err_buffer)
                    @err_pipe = nil if eos
                    stderr_received(data) if data
                    @err_buffer.clear
                end

                nil
            end

            poll do
                poll_live_process unless stub_subprocess
            end

            def poll_live_process
                read_pipes
                pid, exit_status = ::Process.waitpid2(self.pid, ::Process::WNOHANG)
                dead!(exit_status) if pid
            end

            on :stop do |_|
                read_pipes
                @out_pipe&.close
                @err_pipe&.close
            end

            # Create an ExternalProcess task that can be interrupted with the
            # given signal
            def self.interruptible_with_signal(signal: "INT", **arguments)
                InterruptibleWithSignal.new(signal: signal, **arguments)
            end

            # A subclass of {ExternalProcess} that terminates its underlying
            # process with a signal (default is INT)
            #
            # You usually don't create this directly, but use
            # {ExternalProcess.interruptible_with_signal}
            class InterruptibleWithSignal < ExternalProcess
                argument :signal, default: "INT"

                # Time after which the KILL signal gets sent if the process did not
                # terminate
                #
                # Set to nil to disable
                argument :kill_timeout, default: nil

                def kill(signo)
                    super

                    @kill_deadline = Time.now + kill_timeout if kill_timeout
                end

                poll do
                    super()

                    kill("KILL") if @kill_deadline && @kill_deadline < Time.now
                end

                event :failed, terminal: true do |_|
                    if stub_subprocess
                        failed_event.emit
                    else
                        kill(signal)
                    end
                end

                interruptible
            end
        end
    end
end
