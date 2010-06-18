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
app.shell
app.single

robot_name = ARGV.shift
app.robot robot_name, (ARGV.shift || robot_name)
app.setup

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

require 'irb'
require 'irb/ext/save-history'
IRB.setup(remote_url)
IRB.conf[:INSPECT_MODE] = false
IRB.conf[:IRB_NAME]     = remote_url
IRB.conf[:PROMPT_MODE]  = :ROBY
IRB.conf[:AUTO_INDENT] = true
IRB.conf[:HISTORY_FILE] = File.join(APP_DIR, 'config', 'shell_history')
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
		
		msg = begin
			  __main_remote_interface__.poll_messages
		      rescue DRb::DRbConnError
			  []
		      end

		if !msg.empty?
		    STDERR.puts
		    msg.each do |t| 
			STDERR.puts "!" + t.split("\n").join("\n!")
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

