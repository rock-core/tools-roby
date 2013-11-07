module Roby
    module Interface
        # An interface client using TCP that provides reconnection capabilities
        # as well as proper formatting of the information
        class ShellClient < BasicObject
            # @return [String] a string that describes the remote host
            attr_reader :remote_name
            # @return [#call] an object that can create a Client instance
            attr_reader :connection_method
            # @return [Client,nil] the socket used to communicate to the server,
            #   or nil if we have not managed to connect yet
            attr_reader :client
            # @return [Mutex] the shell requires multi-threading access, this is
            #   the mutex to protect when required
            attr_reader :mutex

            def initialize(remote_name, &connection_method)
                @connection_method = connection_method
                @remote_name = remote_name
                @mutex = Mutex.new
                connect
            end

            def path; [] end

            def connect(retry_period = 0.5)
                retry_warning = false
                begin
                    @client = connection_method.call
                rescue ConnectionError, ComError => e
                    if retry_period
                        if e.kind_of?(ComError)
                            Roby::Interface.warn "failed handshake with #{remote_name}, retrying ..."
                        elsif !retry_warning
                            Roby::Interface.warn "cannot connect to #{remote_name}, retrying every #{retry_period} seconds..."
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

            def actions(regex = nil, verbose = false)
                actions = client.actions.sort_by {|act| act.name }
                if regex
                    regex = Regexp.new(regex)
                else
                    regex = Regexp.new(".*")
                end
                actions.each do |action|
                    if regex.match(action.name)
                        if verbose
                            puts "\e[1m#{action.name}!\e[0m"

                            arguments = action.arguments.sort_by {|arg| arg.name }
                            required_arguments = []
                            optional_arguments = []
                            arguments.each do |argument|
                                if argument.required
                                    required_arguments << argument
                                else
                                    optional_arguments << argument
                                end
                            end
                            if !required_arguments.empty?
                                puts "    required arguments"
                                required_arguments.each do |argument|
                                    puts "        #{argument.name}: #{argument.doc} [default: #{argument.default}]"
                                end
                            end
                            if !optional_arguments.empty?
                                puts "    optional arguments:"
                                optional_arguments.each do |argument|
                                    puts "        #{argument.name}: #{argument.doc} [default: #{argument.default}]"
                                end
                            end
                            puts "    doc: #{action.doc}" unless action.doc.empty?
                        else
                            puts "\e[1m#{action.name}!\e[0m(#{action.arguments.map(&:name).sort.join(", ")}): #{action.doc}"
                        end
                    end
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

            def format_notification(source, level, message)
                ["[#{level}] #{source}: #{message}"]
            end

            def summarize_notification(source, level, message)
                return format_notification(source, level, message).first, true
            end

            def format_job_progress(kind, job_id, job_name, *args)
                ["[#{job_id}] #{job_name}: #{kind}"]
            end

            def summarize_job_progress(kind, job_id, job_name, *args)
                return format_job_progress(kind, job_id, job_name, *args).first, true
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
                    client.notification_queue.each do |id, level, message|
                        msg << Roby.console.color("-- ##{id} (notification) --", :bold)
                        msg.concat format_message(kind, level, message)
                        msg << "\n"
                    end
                    client.job_progress_queue.each do |id, (kind, job_id, job_name, *args)|
                        msg << Roby.console.color("-- ##{id} (job progress) --", :bold)
                        msg.concat format_job_progress(kind, job_id, job_name, *args)
                        msg << "\n"
                    end
                    client.exception_queue.each do |id, (kind, exception, tasks)|
                        msg << Roby.console.color("-- ##{id} (#{kind} exception) --", :bold)
                        msg.concat format_exception(kind, exception, tasks)
                        msg << "\n"
                    end
                    client.job_progress_queue.clear
                    client.exception_queue.clear
                    client.notification_queue.clear
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

            # Processes the exception and job_progress queues, and yields with a
            # message that summarizes the new ones
            #
            # @param [Set] already_summarized the set of IDs of messages that
            #   have already been summarized. This should be the value returned by
            #   the last call to {#summarize_pending_messages}
            # @yieldparam [String] msg the message that summarizes the new
            #   exception/job progress
            # @return [Set] the set of notifications still in the queues that
            #   have already been summarized. Pass to the next call to
            #   {#summarize_exception}
            def summarize_pending_messages(already_summarized = Set.new)
                summarized = Set.new
                queues = {:exception => client.exception_queue,
                          :job_progress => client.job_progress_queue,
                          :notification => client.notification_queue}
                queues.each do |type, q|
                    q.delete_if do |id, args|
                        summarized << id
                        if !already_summarized.include?(id)
                            msg, complete = send("summarize_#{type}", *args)
                            yield "##{id} #{msg}"
                            complete
                        end
                    end
                end
                summarized
            end

            # Polls for messages from the remote interface and yields them. It
            # handles automatic reconnection, when applicable, as well
            #
            # It is meant to be called in a separate thread
            #
            # @yieldparam [String] msg messages for the user
            # @param [Float] period the polling period in seconds
            def notification_loop(period = 0.1)
                already_summarized = Set.new
                was_connected = nil
                while true
                    mutex.synchronize do
                        has_valid_connection =
                            begin
                                client.poll
                                true
                            rescue Exception
                                begin
                                    connect(nil)
                                    true
                                rescue Exception
                                end
                            end

                        already_summarized = 
                            summarize_pending_messages(already_summarized) do |msg|
                                yield msg
                            end
                        if has_valid_connection
                            was_connected = true
                        end

                        if has_valid_connection && !was_connected
                            Readline.puts "reconnected"
                        elsif !has_valid_connection && was_connected
                            Readline.puts "lost connection, reconnecting ..."
                        end
                        was_connected = has_valid_connection
                    end
                    sleep period
                end
            end
        end
    end
end
