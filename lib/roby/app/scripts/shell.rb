require 'roby'
require 'roby/distributed'
require 'optparse'

require 'pp'

remote_url = nil
opt = OptionParser.new do |opt|
    opt.on('--host URL', String, "sets the host to connect to") do |url|
	remote_url = url
    end
end
opt.parse! ARGV

app = Roby.app
app.guess_app_dir
app.shell
app.single

robot_name = ARGV.shift
app.robot robot_name, (ARGV.shift || robot_name)
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
        Roby::Interface::ShellClient.new(remote_host, remote_port)
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
            while true
                ok = false
                __main_remote_interface__.mutex.synchronize do
                    begin
                        __main_remote_interface__.client.poll
                        ok = true
                    rescue Exception
                        puts "E"
                    end
                    if !ok
                        begin
                            __main_remote_interface__.connect(nil)
                            ok = true
                        rescue Exception
                        end
                    end
                end

                msg = []
                if ok
                    exceptions    = __main_remote_interface__.exception_queue.size
                    notifications = __main_remote_interface__.notification_queue.size
                    if exceptions > 0
                        msg << "E:#{exceptions}"
                    end
                    if notifications > 0
                        msg << "N:#{notifications}"
                    end
                else msg << "X"
                end
                if !msg.empty?
                    Readline.message "[#{msg.join(",")}] #{remote_url} > "
                else
                    Readline.message "#{remote_url} > "
                end
                sleep 1
            end
        rescue Exception => e
            puts e
        end
    end

    trap("SIGINT") do
	irb.signal_handle
    end
    catch(:IRB_EXIT) do
	irb.eval_input
    end
end

