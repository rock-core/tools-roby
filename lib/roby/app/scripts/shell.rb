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
        Roby::RemoteInterface.new(DRbObject.new_with_uri("druby://#{remote_url}"))
    rescue DRb::DRbConnError
        STDERR.puts "cannot connect to a Roby controller at #{remote_url}, is the controller started ?"
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

    trap("SIGINT") do
	irb.signal_handle
    end

    # Create a thread which reads the remote messages and display them if needed
    Thread.new do
	begin
	    loop do
		sleep(1)
		
		msgs = begin
			  __main_remote_interface__.poll_messages
		      rescue DRb::DRbConnError
			  []
		      end

                if !msgs.empty?
                    STDERR.puts
                end

                msgs.each do |level, lines|
                    if !lines.respond_to?(:to_ary)
                        lines = [lines]
                    end

                    first_line = lines.shift
                    if !lines.empty?
                        first_line = "= #{first_line}"
                        lines = lines.map do |str|
                            "| #{str}"
                        end
                        lines << ""
                    end

                    if level == :error
                        first_line = Roby.color(first_line, :red, :bold)
                    elsif level == :info
                        first_line = Roby.color(first_line, :bold)
                    end
                    STDERR.puts first_line
                    lines.each do |l|
                        STDERR.puts l
                    end
                end
	    end
	rescue Exception => e
	    STDERR.puts $!.full_message
	end
    end

    catch(:IRB_EXIT) do
	irb.eval_input
    end
end

