require 'roby'
require 'optparse'
require 'rb-readline'

app = Roby.app
app.guess_app_dir
app.shell
app.single
app.load_config_yaml

require 'pp'

remote_url = nil
silent = false
opt = OptionParser.new do |opt|
    opt.on('--host URL', String, "sets the host to connect to") do |url|
	remote_url = url
    end
    opt.on '--silent', 'disable notifications (can also be controlled in the shell itself)' do
        silent = true
    end
end
opt.parse! ARGV

error = Roby.display_exception do
    app.base_setup

    if !remote_url
        remote_url = "#{app.shell_interface_host}:#{app.shell_interface_port}"
    elsif remote_url !~ /:\d+$/
        remote_url += ":#{app.shell_interface_port}"
    end
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

__main_remote_interface__.silent(silent)

module RbReadline
    def self.puts(msg)
        if needs_save_and_restore = rl_isstate(RL_STATE_READCMD)
            saved_point = rl_point
            rl_maybe_save_line
            rl_save_prompt
            rl_kill_full_line(nil, nil)
            rl_redisplay
        end

        Kernel.puts msg

        if needs_save_and_restore
            rl_restore_prompt
            rl_maybe_replace_line
            @rl_point = saved_point
            rl_redisplay
        end
    end
end

class SynchronizedReadlineInput < IRB::ReadlineInputMethod
    def initialize(mutex)
        @mutex = mutex
        super()
    end

    def gets
        mutex.synchronize { super }
    end
end

begin
    # Make __main_remote_interface__ the top-level object
    bind = __main_remote_interface__.instance_eval { binding }
    ws  = IRB::WorkSpace.new(bind)
    irb = IRB::Irb.new(ws)

    context = IRB::Context.new(irb, ws, SynchronizedReadlineInput.new(__main_remote_interface__.mutex))
    context.save_history = 100
    IRB.conf[:MAIN_CONTEXT] = irb.context

    Thread.new do
        begin
            __main_remote_interface__.notification_loop(0.1) do |msg|
                if !__main_remote_interface__.silent?
                    RbReadline.puts(msg)
                end
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

