require 'roby'
require 'roby/app'
require 'roby/distributed'
require 'roby/distributed/protocol'
require 'optparse'

remote_url = nil
if ARGV.include?("--remote")
    opt = OptionParser.new do |opt|
	opt.on('--remote [URL]', String, "connect to a remote Roby engine") do |url|
	    remote_url = url || ""
	    unless remote_url =~ /:\d+$/
		remote_url << ":#{Roby::Distributed::DEFAULT_DROBY_PORT}"
	    end
	end
    end
    opt.parse! ARGV
else
    require File.join(File.dirname(__FILE__), '..', 'run')
end

app = Roby.app

robot_name = ARGV.shift
app.robot robot_name, (ARGV.shift || robot_name)
require File.join(File.dirname(__FILE__), '..', 'load')
app.droby['host'] = ":0"
app.setup

require 'irb'
IRB.setup(nil)

control = if remote_url
	      Roby::RemoteInterface.new(DRbObject.new_with_uri("roby://#{remote_url}"))
	  else
	      Roby::Interface.new(Roby.control)
	  end

begin
    # Make control the top-level object
    bind = control.instance_eval { binding }
    ws  = IRB::WorkSpace.new(bind)
    irb = IRB::Irb.new(ws)
    IRB.conf[:MAIN_CONTEXT] = irb.context

    trap("SIGINT") do
	irb.signal_handle
    end

    # Create a thread which reads the remote messages and display them if needed
    Thread.new do
	loop do
	    sleep(1)
	    msg = control.poll_messages
	    if !msg.empty?
		STDERR.puts
		msg.each do |t| 
		    STDERR.puts "!" + t.split("\n").join("\n!")
		end
	    end
	end
    end

    if remote_url
	catch(:IRB_EXIT) do
	    irb.eval_input
	end
    else
	app.run do
	    Roby.execute do
		load File.join(APP_DIR, "controllers", "#{app.robot_name}.rb")
	    end
	    catch(:IRB_EXIT) do
		irb.eval_input
	    end
	end
    end

rescue Interrupt
    Roby.control.quit
    Roby.control.join
ensure 
    Roby.control.join
end

