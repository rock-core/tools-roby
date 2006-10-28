require 'drb'
require 'roby/support'
require 'roby/task'
require 'roby/event'
require 'roby/plan'
require 'facet/kernel/constant'

module Roby::Display
    DEFAULT_REMOTE_DISPLAY_URI = "druby://localhost:10000"

    module DRbDisplayMixin
	attr_accessor :changed
	def changed?; @changed end
	def changed!; @changed = true end

	attr_accessor :server
	def close_event(event)
	    super
	    server.delete(self)
	end
    end

    class DRbDisplayThread < ThreadServer
	attr_reader :remote_display
	def initialize(remote_display, forward_to, multiplex = false)
	    @remote_display = remote_display
	    super(forward_to, multiplex)
	end

	def process_messages
	    super

	rescue RuntimeError => e
	    Roby.warn "display server #{self} disabled because of exception: #{e.message}(#{e.class})"
	    remote_display.disable

	    raise ThreadServer::Quit
	end
    end

    # A remote display server as a standalone Qt application
    class DRbRemoteDisplay
	# URI => server map
	@@servers = Hash.new
	# Server => Thread map
	@@threads = Hash.new

	# The display server
	attr_reader :display_server
	# The remote display itself
	attr_reader :display
	# The display thread
	attr_reader :display_thread

	# Start the display server in a standalone process
	# and spawn a DRb server to allow connections to it
	#
	# +control_pipe+ can be used to notify a parent process
	# that the initialization has been done properly
	def standalone(uri, control_pipe = nil)
	    require 'drb-qt'
	    a = Qt::Application.new( ARGV )

	    server = DRbDisplayServer.new(uri)
	    if control_pipe
		control_pipe.write("OK")
		control_pipe.close
	    end

	    a.setMainWidget( server.main_window )
	    a.exec()

	rescue Exception => e
	    STDERR.puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
	end

	# Connects to a display server
	# 
	# :start => true if we should start a standalone display, false if we connect to an already existing one
	# :server => uri the URI on which we should connect to the server
	# :server => DRbObject the server object
	def connect(kind, options)
	    raise RuntimeError, "already started" if @display
	    options = validate_options options, :start => false, 
		:server => DEFAULT_REMOTE_DISPLAY_URI, 
		:name => nil

	    if options[:start]
		read, write = IO.pipe
		fork do
		    read.close
		    standalone(options[:server], write)
		end

		write.close
		check = read.read(2)
		if check != "OK"
		    raise RuntimeError, "failed to start #{self.class}"
		end
	    end

	    # Get the display server object
	    @display_server = if options[:server].respond_to?(:to_str)
				  DRb.start_service unless DRb.primary_server
				  uri = options[:server].to_str
				  @@servers[uri] ||= DRbObject.new(nil, options[:server].to_str)
			      else options[:server]
				  options[:server]
			      end

	    @display = display_server.get(Process.pid, kind, options[:name])
	    @display_thread = (@@threads[@display_server] ||= DRbDisplayThread.new(self, display_server, true))

	    self
	end

	def delete
	    display_server.delete(display) if display
	    disconnected
	end

	def disconnected
	    @display = nil
	    @display_server = nil
	    @display_thread = nil
	end
	def connected?; @display end

	def flush; display_thread.flush if display_thread end
    end
end

