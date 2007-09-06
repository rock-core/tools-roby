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
app.setup

DRb.start_service

require 'irb'
IRB.setup(nil)

control = if remote_url
	      Roby::RemoteInterface.new(DRbObject.new_with_uri("druby://#{remote_url}"))
	  else
	      Roby::Interface.new(Roby.control)
	  end

begin
    # Make control the top-level object
    bind = control.instance_eval { binding }
    ws  = IRB::WorkSpace.new(bind)
    irb = IRB::Irb.new(ws)

    context = irb.context
    def context.evaluate(*args, &block)
	Roby.execute do
	    super
	end
    end
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
			  control.poll_messages
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
	rescue
	    STDERR.puts $!.full_message
	ensure
	    STDERR.puts "message polling died"
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
	    begin
		catch(:IRB_EXIT) do
		    irb.eval_input
		end
	    ensure
		Roby.control.quit
	    end
	end
    end
end

