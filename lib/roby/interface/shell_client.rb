module Roby
    module Interface
        # An interface client using TCP that provides reconnection capabilities
        # as well as proper formatting of the information
        class ShellClient < BasicObject
            # @return [String] the host we are connecting to
            attr_reader :host
            # @return [Integer] the port we are connecting to
            attr_reader :port
            # @return [Client,nil] the socket used to communicate to the server,
            #   or nil if we have not managed to connect yet
            attr_reader :client
            # @return [Mutex] the shell requires multi-threading access, this is
            #   the mutex to protect when required
            attr_reader :mutex

            def initialize(host, port)
                @host, @port = host, port
                @mutex = Mutex.new
                connect
            end

            def path; [] end

            def connect(retry_period = 0.5)
                retry_warning = false
                begin
                    @client = ::Roby::Interface.connect_with_tcp_to(host, port)
                rescue ConnectionError, ComError => e
                    if retry_period
                        if e.kind_of?(ComError)
                            Roby::Interface.warn "failed handshake with #{host}:#{port}, retrying ..."
                        elsif !retry_warning
                            Roby::Interface.warn "cannot connect to #{host}:#{port}, retrying every #{retry_period} seconds..."
                            retry_warning = true
                        end
                        sleep retry_period
                        retry
                    else raise
                    end
                end
            end

            def close
                client.close
                @client = nil
            end

            def actions
                actions = call Hash[:retry => true], [], :actions
                actions.each do |action|
                    puts "#{action.name}!(#{action.arguments.map(&:name).sort.join(", ")}): #{action.doc}"
                end
                nil
            end

            def jobs
                jobs = call Hash[:retry => true], [], :jobs
                jobs.each do |id, name|
                    puts "[%4d] %s" % [id, name]
                end
                nil
            end

            def retry_on_com_error
                yield
            rescue ComError
                Roby::Interface.warn "Lost communication with remote, retrying command after reconnection"
                connect
                retry
            end

            def describe(matcher)
                if matcher.kind_of?(Roby::Actions::Action)
                    pp matcher.model
                elsif matcher.kind_of?(Roby::Actions::Model::Action)
                    pp matcher
                else
                    client.find_all_actions_matching(matcher).each do |act|
                        pp act
                    end
                end
                nil
            end

            def call(options, path, m, *args)
                options = Kernel.validate_options options, :retry => false
                if options[:retry]
                    options = options.merge(:retry => false)
                    retry_on_com_error do
                        return call options, path, m, *args
                    end
                else
                    @mutex.synchronize do
                        client.call(path, m, *args)
                    end
                end
            end

            def format_notification(kind, job_id, job_name, *args)
                ["[#{job_id}] #{job_name}: #{kind}"]
            end

            def summarize_notification(kind, job_id, job_name, *args)
                return format_notification(kind, job_id, job_name, *args).first, true
            end

            def format_exception(kind, error, *args)
                color = if kind == ExecutionEngine::EXCEPTION_FATAL then [:red]
                        elsif kind == ExecutionEngine::EXCEPTION_NONFATAL then [:magenta]
                        else []
                        end
                if error
                    msg = Roby.format_exception(error.exception)
                    if msg[0]
                        msg[0] = Roby.console.color(msg[0], *color)
                    end
                else
                    msg = ["<something wrong happened in transmission of exception information>"]
                end
                return msg
            end

            def summarize_exception(kind, error, *args)
                msg = "(#{kind}) #{format_exception(kind, error, *args).first}"
                return msg, false
            end

            def wtf?
                msg = []
                @mutex.synchronize do
                    client.notification_queue.each do |id, (kind, job_id, job_name, *args)|
                        msg << Roby.console.color("-- ##{id} (notification) --", :bold)
                        msg.concat format_notification(kind, job_id, job_name, *args)
                        msg << "\n"
                    end
                    client.exception_queue.each do |id, (kind, exception, tasks)|
                        msg << Roby.console.color("-- ##{id} (#{kind} exception) --", :bold)
                        msg.concat format_exception(kind, exception, tasks)
                        msg << "\n"
                    end
                    client.notification_queue.clear
                    client.exception_queue.clear
                end
                puts msg.join("\n")
                nil
            end

            def method_missing(m, *args, &block)
                if sub = client.find_subcommand_by_name(m.to_s)
                    ShellSubcommand.new(self, m.to_s, sub.description, sub.commands)
                elsif act = client.find_action_by_name(m.to_s)
                    Roby::Actions::Action.new(act, *args)
                else
                    begin
                        call Hash[], [], m, *args
                    rescue NoMethodError => e
                        if e.message =~ /undefined method .#{m}./
                            puts "invalid command name #{m}, call 'help' for more information"
                        else raise
                        end
                    rescue ArgumentError => e
                        if e.message =~ /wrong number of arguments/ && e.backtrace.first =~ /#{m.to_s}/
                            puts e.message
                        else raise
                        end
                    end
                end
            rescue ComError
                Roby::Interface.warn "Lost communication with remote, will not retry the command after reconnection"
                mutex.synchronize do
                    connect
                end
            rescue Interrupt
                Roby::Interface.warn "Interrupted"
            end

            def help(subcommand = client)
                puts
                if subcommand.respond_to?(:description)
                    puts Roby.console.color(subcommand.description.join("\n"), :bold)
                    puts
                end

                commands = subcommand.commands[''].commands
                if !commands.empty?
                    puts Roby.console.color("Commands", :bold)
                    puts Roby.console.color("--------", :bold)
                    commands.keys.sort.each do |command_name|
                        cmd = commands[command_name]
                        puts "#{command_name}(#{cmd.arguments.keys.map(&:to_s).join(", ")}): #{cmd.description.first}"
                    end
                end
                if subcommand.commands.size > 1
                    puts if !commands.empty?
                    puts Roby.console.color("Subcommands (use help <subcommand name> for more details)", :bold)
                    puts Roby.console.color("-----------", :bold)
                    subcommand.commands.keys.sort.each do |subcommand_name|
                        next if subcommand_name.empty?
                        puts "#{subcommand_name}: #{subcommand.commands[subcommand_name].description.first}"
                    end
                end
                nil
            end
        end
    end
end
