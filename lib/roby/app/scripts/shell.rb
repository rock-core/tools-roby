require 'roby'
require 'roby/distributed'
require 'optparse'
require 'utilrb/readline'

app = Roby.app
app.guess_app_dir
app.shell
app.single
app.load_config_yaml

require 'pp'

remote_url = nil
opt = OptionParser.new do |opt|
    opt.on('--host URL', String, "sets the host to connect to") do |url|
	remote_url = url
    end
end
opt.parse! ARGV

error = Roby.display_exception do
    app.base_setup

    remote_url ||= app.droby['host']
    remote_url ||= 'localhost'
    if remote_url !~ /:\d+$/
        if app.droby['host'] && app.droby['host'] =~ /(:\d+)$/
            remote_url << $1
        else
            remote_url << ":#{Roby::Distributed::DEFAULT_DROBY_PORT}"
        end
    end

    DRb.start_service
end
if error
    exit(1)
end

require 'irb'
require 'irb/ext/save-history'
IRB.setup(remote_url)
IRB.conf[:INSPECT_MODE] = false
IRB.conf[:IRB_NAME]     = remote_url
IRB.conf[:USE_READLINE] = true
IRB.conf[:PROMPT_MODE]  = :ROBY
IRB.conf[:AUTO_INDENT] = true
if Roby.app.app_dir
    IRB.conf[:HISTORY_FILE] = File.join(Roby.app.app_dir, 'config', 'shell_history')
end
IRB.conf[:SAVE_HISTORY] = 1000
IRB.conf[:PROMPT][:ROBY] = {
    :PROMPT_I => "%N > ",
    :PROMPT_N => "%N > ",
    :PROMPT_S => "%N %l ",
    :PROMPT_C => "%N * ",
    :RETURN => "=> %s\n"
}

Roby::Distributed::DRobyModel.add_anonmodel_to_names = false
__main_remote_interface__ = 
    begin
        remote_url =~ /^(.*):(\d+)$/
        remote_host, remote_port = $1, Integer($2)
        Roby::Interface::ShellClient.new("#{remote_host}:#{remote_port}") do
            Roby::Interface.connect_with_tcp_to(remote_host, remote_port)
        end
    rescue Interrupt
        Roby::Interface.warn "Interrupted by user"
        exit(1)
    end

begin
    # Make __main_remote_interface__ the top-level object
    bind = __main_remote_interface__.instance_eval { binding }
    ws  = IRB::WorkSpace.new(bind)
    irb = IRB::Irb.new(ws)

    context = irb.context
    context.save_history = 100
    IRB.conf[:MAIN_CONTEXT] = irb.context

    Thread.new do
        begin
            already_summarized = Set.new
            while true
                was_connected = nil
                __main_remote_interface__.mutex.synchronize do
                    has_valid_connection =
                        begin
                            __main_remote_interface__.client.poll
                            true
                        rescue Exception
                            begin
                                __main_remote_interface__.connect(nil)
                                true
                            rescue Exception
                            end
                        end

                    summarized = Set.new
                    __main_remote_interface__.client.exception_queue.delete_if do |id, args|
                        summarized << id
                        if !already_summarized.include?(id)
                            msg, complete = __main_remote_interface__.summarize_exception(*args)
                            Readline.puts "##{id} #{msg}"
                            complete
                        end
                    end
                    __main_remote_interface__.client.notification_queue.delete_if do |id, args|
                        summarized << id
                        if !already_summarized.include?(id)
                            msg, complete = __main_remote_interface__.summarize_notification(*args)
                            Readline.puts "##{id} #{msg}"
                            complete
                        end
                    end
                    already_summarized = summarized
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
                sleep 0.1
            end
        rescue Exception => e
            puts e
            puts e.backtrace.join("\n")
        end
    end

    trap("SIGINT") do
	irb.signal_handle
    end
    catch(:IRB_EXIT) do
	irb.eval_input
    end
end

