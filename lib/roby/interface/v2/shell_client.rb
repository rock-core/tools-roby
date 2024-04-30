# frozen_string_literal: true

module Roby
    module Interface
        module V2
            # An interface client using TCP that provides reconnection capabilities
            # as well as proper formatting of the information
            class ShellClient
                # @return [String] a string that describes the remote host
                attr_reader :remote_name
                # @return [#call] an object that can create a Client instance
                attr_reader :connection_method
                # @return [Client,nil] the socket used to communicate to the server,
                #   or nil if we have not managed to connect yet
                attr_reader :client

                attr_predicate :silent?, false

                def initialize(remote_name, &connection_method)
                    @connection_method = connection_method
                    @remote_name = remote_name
                    @silent = false
                    connect
                end

                def path
                    []
                end

                def connect(retry_period = 0.5)
                    retry_warning = false
                    begin
                        @client = connection_method.call
                        @batch = client.create_batch
                        @batch_job_info = {}
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
                        else
                            raise
                        end
                    end
                end

                def closed?
                    client.closed?
                end

                def close
                    client.close
                    @job_manager = nil
                    @client = nil
                end

                def actions(regex = nil, verbose = false)
                    actions = client.actions.sort_by(&:name)
                    if regex
                        regex = Regexp.new(regex)
                    else
                        regex = Regexp.new(".*")
                    end
                    actions.each do |action|
                        if regex.match(action.name)
                            if verbose
                                puts "\e[1m#{action.name}!\e[0m"

                                arguments = action.arguments.sort_by(&:name)
                                required_arguments = []
                                optional_arguments = []
                                arguments.each do |argument|
                                    if argument.required
                                        required_arguments << argument
                                    else
                                        optional_arguments << argument
                                    end
                                end
                                unless required_arguments.empty?
                                    puts "    required arguments"
                                    required_arguments.each do |argument|
                                        puts "        #{argument.name}: #{argument.doc} [default: #{argument.default}]"
                                    end
                                end
                                unless optional_arguments.empty?
                                    puts "    optional arguments:"
                                    optional_arguments.each do |argument|
                                        puts "        #{argument.name}: #{argument.doc} [default: #{argument.default}]"
                                    end
                                end
                                puts "    doc: #{action.doc}" unless action.doc.empty?
                            else
                                puts "\e[1m#{action.name}!\e[0m(#{action.arguments.map(&:name).sort.join(', ')}): #{action.doc}"
                            end
                        end
                    end
                    nil
                end

                def format_arguments(hash)
                    hash.keys.map do |k|
                        v = hash[k]
                        v = if !v || v.respond_to?(:to_str) then v.inspect
                            else
                                v
                            end
                        "#{k} => #{v}"
                    end.join(", ")
                end

                def __jobs
                    call Hash[retry: true], [], :jobs
                end

                def jobs
                    jobs = __jobs
                    jobs.each do |id, job_info|
                        puts format_job_info(id, *job_info)
                    end
                    nil
                end

                def format_job_info(id, state, task, planning_task)
                    if planning_task.arguments[:action_model]
                        name = "#{planning_task.arguments[:action_model].name}(#{format_arguments(planning_task.arguments[:action_arguments])})"
                    else
                        name = "#{task.model}<id:#{task.id}>"
                    end
                    format("[%4d] (%s) %s", id, state.to_s, name)
                end

                def retry_on_com_error
                    yield
                rescue ComError
                    Roby::Interface.warn "Lost communication with remote, retrying command after reconnection"
                    connect
                    retry
                end

                def describe(matcher)
                    if matcher.kind_of?(Protocol::Action)
                        display_action(matcher)
                    elsif matcher.kind_of?(Protocol::ActionModel)
                        display_action_model(matcher)
                    end
                    nil
                end

                def display_action_model(act)
                    puts "#{act.name}     #{act.doc}"
                    act.arguments.each do |arg|
                        puts "  #{arg.name} - #{arg.doc}"
                        puts "                #{arg.required ? 'required' : 'optional'}"
                        unless arg.default.kind_of?(Protocol::VoidClass)
                            puts "                default: #{arg.default}"
                        end
                        unless arg.example.kind_of?(Protocol::VoidClass)
                            puts "                example: #{arg.example}"
                        end
                    end
                end

                def display_action(act)
                    puts act.model.name
                    act.arguments.each do |arg|
                        puts "  #{arg}"
                    end
                end

                def call(options, path, m, *args)
                    options = Kernel.validate_options options, retry: false
                    if options[:retry]
                        options = options.merge(retry: false)
                        retry_on_com_error do
                            return call options, path, m, *args
                        end
                    else
                        client.call(path, m, *args)
                    end
                rescue Exception => e
                    msg = Roby.format_exception(e)
                    if msg[0]
                        msg[0] = Roby.color(msg[0], :red)
                    end
                    puts msg.join("\n")
                    puts "  #{e.backtrace.join('\n  ')}"
                    nil
                end

                def format_notification(source, level, message)
                    ["[#{level}] #{source}: #{message}"]
                end

                def summarize_notification(source, level, message)
                    [format_notification(source, level, message).first, true]
                end

                def format_job_progress(kind, job_id, job_name, *args)
                    ["[#{job_id}] #{job_name}: #{kind}"]
                end

                def summarize_job_progress(kind, job_id, job_name, *args)
                    [format_job_progress(kind, job_id, job_name, *args).first, true]
                end

                def format_exception(kind, error, *args)
                    color =
                        case kind
                        when ExecutionEngine::EXCEPTION_FATAL
                            [:red]
                        when ExecutionEngine::EXCEPTION_NONFATAL
                            [:magenta]
                        else
                            []
                        end

                    if error
                        msg = Roby.format_exception(error.exception)
                        if msg[0]
                            msg[0] = Roby.color(msg[0], *color)
                        end
                    else
                        msg = ["<something wrong happened in transmission of exception information>"]
                    end
                    msg
                end

                def summarize_exception(kind, error, *args)
                    msg = "(#{kind}) #{format_exception(kind, error, *args).first}"
                    [msg, false]
                end

                def wtf?
                    msg = []
                    client.notification_queue.each do |id, (source, level, message)|
                        msg << Roby.color("-- ##{id} (notification) --", :bold)
                        msg.concat format_notification(source, level, message)
                        msg << "\n"
                    end
                    client.job_progress_queue.each do |id, (kind, job_id, job_name, *args)|
                        msg << Roby.color("-- ##{id} (job progress) --", :bold)
                        msg.concat format_job_progress(kind, job_id, job_name, *args)
                        msg << "\n"
                    end
                    client.exception_queue.each do |id, (kind, exception, tasks)|
                        msg << Roby.color("-- ##{id} (#{kind} exception) --", :bold)
                        msg.concat format_exception(kind, exception, tasks)
                        msg << "\n"
                    end
                    client.job_progress_queue.clear
                    client.exception_queue.clear
                    client.notification_queue.clear
                    puts msg.join("\n")
                    nil
                end

                def safe?
                    !!@batch
                end

                def safe
                    @batch ||= client.create_batch
                    nil
                end

                def unsafe
                    @batch = nil
                end

                def resolve_job_id(job_id)
                    if job_info = __jobs[job_id]
                        job_info
                    else
                        STDERR.puts Roby.color("No job #{job_id}", :bold, :bright_red)
                    end
                end

                def kill_job(job_id)
                    if safe?
                        if @batch_job_info[job_id] = resolve_job_id(job_id)
                            @batch.kill_job job_id
                            review
                        end
                    else
                        super
                    end
                    nil
                end

                def drop_job(job_id)
                    if safe?
                        if @batch_job_info[job_id] = resolve_job_id(job_id)
                            @batch.drop_job job_id
                            review
                        end
                    else
                        super
                    end
                    nil
                end

                def review
                    if safe?
                        puts "#{@batch.__calls.size} actions queued in the current batch, "\
                             "use #process to send, #cancel to delete"
                        @batch.__calls.each do |context, m, *args|
                            if %i[drop_job kill_job].include?(m)
                                job_id = args.first
                                job_info = format_job_info(job_id, *@batch_job_info[job_id])
                                puts "#{Roby.color(m.to_s, :bold, :bright_red)} #{job_info}"
                            elsif m == :start_job
                                puts "#{Roby.color("#{args[0]}!", :bright_blue)}(#{args[1]})"
                            else
                                puts "#{Roby.color("#{m}!", :bright_blue)}(#{args.first})"
                            end
                        end
                    end
                    nil
                end

                def process
                    if safe?
                        @batch.__process
                    else
                        STDERR.puts "Not in batch context"
                    end
                    @batch = client.create_batch
                    nil
                end

                def cancel
                    @batch = client.create_batch
                    review
                    nil
                end

                def method_missing(m, *args)
                    if sub = client.find_subcommand_by_name(m.to_s)
                        ShellSubcommand.new(self, m.to_s, sub.description, sub.commands)
                    elsif act = client.find_action_by_name(m.to_s)
                        act
                    elsif @batch && m.to_s =~ /(.*)!$/
                        action_name = $1
                        @batch.start_job(action_name, *args)
                        review
                        nil
                    else
                        begin
                            call Hash[], [], m, *args
                        rescue NoMethodError => e
                            if e.message =~ /undefined method .#{m}./
                                puts "invalid command name #{m}, call 'help' for more information"
                            else
                                raise
                            end
                        rescue ArgumentError => e
                            if e.message =~ /wrong number of arguments/ && e.backtrace.first =~ /#{m}/
                                puts e.message
                            else
                                raise
                            end
                        end
                    end
                rescue ComError
                    Roby::Interface.warn "Lost communication with remote, will not retry the command after reconnection"
                    connect
                rescue Interrupt
                    Roby::Interface.warn "Interrupted"
                end

                def help(subcommand = client)
                    # IRB nowadays converts `help syskit` into `help "syskit"`
                    if subcommand.kind_of?(String)
                        subcommand_name = subcommand
                        subcommand = client.find_subcommand_by_name(subcommand_name)
                        unless subcommand
                            raise ArgumentError, "no subcommand '#{subcommand}'"
                        end
                    end

                    puts
                    if safe?
                        puts Roby.color("Currently in safe mode, use 'unsafe' to switch", :bold)
                        puts "Job commands like drop_job, kill_job, ... are queued, only sent if on 'process'"
                        puts "review           display the pending job commands"
                        puts "process          apply the pending job commands"
                        puts "cancel           clear the pending job commands"
                    else
                        puts Roby.color("Currently in unsafe mode, use 'safe' to switch", :bold, :red)
                        puts "Job commands like drop_job, kill_job, ... are sent directly"
                    end

                    puts
                    if subcommand.respond_to?(:description)
                        puts Roby.color(subcommand.description.join("\n"), :bold)
                        puts
                    end

                    commands = subcommand.commands[""].commands
                    unless commands.empty?
                        puts Roby.color("Commands", :bold)
                        puts Roby.color("--------", :bold)
                        commands.keys.sort.each do |command_name|
                            cmd = commands[command_name]
                            puts "#{command_name}(#{cmd.arguments.keys.map(&:to_s).join(', ')}): #{cmd.description.first}"
                        end
                    end
                    if subcommand.commands.size > 1
                        puts unless commands.empty?
                        puts Roby.color("Subcommands (use help <subcommand name> for more details)", :bold)
                        puts Roby.color("-----------", :bold)
                        subcommand.commands.keys.sort.each do |sub_name|
                            next if sub_name.empty?

                            puts "#{sub_name}: #{subcommand.commands[sub_name].description.first}"
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
                    messages = []
                    queues = { exception: client.exception_queue,
                               job_progress: client.job_progress_queue,
                               notification: client.notification_queue }
                    queues.each do |type, q|
                        q.delete_if do |id, args|
                            summarized << id
                            unless already_summarized.include?(id)
                                msg, complete = send("summarize_#{type}", *args)
                                messages << "##{id} #{msg}"
                                complete
                            end
                        end
                    end
                    [summarized, messages]
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
                    loop do
                        has_valid_connection =
                            begin
                                client.poll
                                true
                            rescue Exception
                                begin
                                    connect(nil)
                                    client.io.reset_thread_guard
                                    true
                                rescue Exception
                                end
                            end

                        already_summarized, messages =
                            summarize_pending_messages(already_summarized)
                        yield(has_valid_connection, messages)
                        if has_valid_connection
                            was_connected = true
                        end

                        if has_valid_connection && !was_connected
                            RbReadline.puts "reconnected"
                        elsif !has_valid_connection && was_connected
                            RbReadline.puts "lost connection, reconnecting ..."
                        end
                        was_connected = has_valid_connection

                        sleep period
                    end
                end

                # Whether the shell should stop displaying any notification
                def silent(silent) # rubocop:disable Style/TrivialAccessors
                    @silent = silent
                end

                # Make the remote app quit
                #
                # This is defined explicitely because otherwise IRB "hooks" on quit
                # to terminate the shell instead
                def quit
                    call({}, [], :quit)
                end
            end
        end
    end
end
