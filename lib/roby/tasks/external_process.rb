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
            argument :working_directory

            # Redirection specification. See #redirect_output
            attr_reader :redirection

            def initialize(arguments)
                arguments[:working_directory] ||= nil
                            arguments[:command_line] = [arguments[:command_line]] unless arguments[:command_line].kind_of?(Array)
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

            ##
            # :method: start!
            #
            # Starts the child process. Emits +start+ when the process is actually
            # started.
            event :start do |context|
                working_directory = (self.working_directory || Dir.pwd)
                options = Hash[pgroup: 0, chdir: working_directory]

                opened_ios = Array.new
                if redirection.respond_to?(:to_str)
                    io = open_redirection(working_directory)
                    options[:out] = options[:err] = io
                    opened_ios << [redirection, io]
                elsif redirection
                    if redirection[:stdout]
                        io = open_redirection(working_directory) 
                        options[:out] = io
                        opened_ios << [redirection[:stdout], io]
                    end
                    if redirection[:stderr]
                        io = open_redirection(working_directory) 
                        options[:err] = io
                        opened_ios << [redirection[:stderr], io]
                    end
                end

                @pid = Process.spawn *command_line, **options
                opened_ios.each do |pattern, io|
                    FileUtils.mv io.path, File.join(working_directory, redirection_path(pattern, @pid))
                end

                start_event.emit
            end

            # Returns the file name based on the redirection pattern and the current
            # PID values. This is called in the child process before exec().
            def redirection_path(pattern, pid) # :nodoc:
                pattern.gsub '%p', pid.to_s
            end

            def open_redirection(dir)
                Dir::Tmpname.create 'roby-external-process', dir do |path, _|
                    return File.open(path, 'w+')
                end
            end

            # Kills the child process
            def kill(signo)
                Process.kill(signo, pid)
            end

            poll do
                pid, exit_status = ::Process.waitpid2(self.pid, ::Process::WNOHANG)
                if pid
                    dead!(exit_status)
                end
            end
        end
    end
end

