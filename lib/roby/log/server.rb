require 'roby/log'
require 'roby/log/data_stream'
require 'roby/distributed/communication'
require 'roby/distributed/drb'
require 'tempfile'

module Roby
    module Log
	class Server
	    RING_PORT = 48933

	    class << self
		attr_reader :logger
	    end
	    @logger = Logger.new(STDERR)
	    @logger.level = Logger::INFO
	    @logger.progname = "Roby server"
	    @logger.formatter = lambda { |severity, time, progname, msg| "#{time.to_hms} #{progname} #{msg}\n" }
	    extend Logger::Forward

	    @mutex = Mutex.new
	    def self.synchronize
		@mutex.synchronize { yield }
	    end

	    # Returns the set of servers that have been discovered by the discovery
	    # mechanism at this time
	    #
	    # See also enable_discovery and disable_discovery
	    def self.available_servers
		synchronize do
		    @available_servers.dup
		end
	    end

	    # Start an asynchronous discovery mechanism. This will fill the
	    # #available_servers set of servers. +broadcast+ is an array of
	    # addresses on which discovery should be done and +period+ is the
	    # discovery period in seconds
	    def self.enable_discovery(broadcast, port = RING_PORT, period = 10)
		if @discovery_thread
		    raise ArgumentError, "already enabled discovery"
		end

		finger = Rinda::RingFinger.new(broadcast, port)

		discovered_displays = Array.new
		@available_servers  = Array.new

		# Add disable_discovery in the list of finalizers
		Control.finalizers << method(:disable_discovery)

		@discovery_thread = Thread.new do
		    begin
			loop do
			    finger.lookup_ring(period) do |remote|
				synchronize do
				    unless @available_servers.include?(remote)
					@available_servers << remote
				    end
				    discovered_displays << remote
				end
			    end
			    sleep(period)

			    synchronize do
				@available_servers, discovered_displays = discovered_displays, @available_servers
				discovered_displays.clear
			    end
			end
		    rescue Interrupt
		    end
		end
	    end

	    # Stops the discovery thread if it is running
	    def self.disable_discovery
		Control.finalizers.delete(method(:disable_discovery))
		if @discovery_thread
		    @discovery_thread.raise Interrupt, "quitting"
		    @discovery_thread.join
		    @discovery_thread = nil

		    synchronize do
			@available_servers.clear
		    end
		end
	    end

	    # A <tt>stream_id => [remote_server, ...]</tt> hash containing the
	    # set of subscribed remote peer for each stream
	    attr_reader :subscriptions
	    # A <tt>remote_server => [queue, thread]</tt> hash which contains
	    # the set of connection parameters for each connected peer
	    attr_reader :connections

	    # The Distributed::RingServer object which publishes this display
	    # server on the network
	    attr_reader :ring_server

	    # Default value for #polling_timeout
	    POLLING_TIMEOUT = 0.1

	    attr_reader :polling_timeout

	    attr_predicate :take_over

	    def initialize(take_over = false, port = RING_PORT, polling_timeout = POLLING_TIMEOUT)
		@ring_server = Distributed::RingServer.new(DRbObject.new(self), :port => port)
		@mutex   = Mutex.new
		@streams = Array.new
		@connections = Hash.new
		@subscriptions = Hash.new { |h, k| h[k] = Set.new }
		@polling_timeout = polling_timeout
		@polling = Thread.new(&method(:polling))
		@take_over = take_over
	    end

	    def synchronize
		@mutex.synchronize { yield }
	    end

	    def connect(remote)
		synchronize do
		    queue = Distributed::CommunicationQueue.new
		    receiver_thread = pushing_loop(remote, queue)
		    connections[remote] = [queue, receiver_thread]

		    Server.info "#{remote.__drburi} connected"
		end
		streams.map do |s|
		    [s.class.name, s.id, s.name, s.type]
		end
	    end

	    def disconnect(remote)
		thread = synchronize do
		    queue, thread = connections[remote]
		    if thread
			thread.raise Interrupt, "quitting"
			thread
		    end
		end
		thread.join if thread

		Server.info "#{remote.__drburi} disconnected"
	    end

	    # Polls all data sources and pushes the samples to the subscribed
	    # clients
	    def polling
		loop do
		    s, data = nil
		    done_sth = false
		    synchronize do
			@streams.each do |s|
			    done_sth ||= if s.reinit?
					     Roby::Log::Server.info "reinitializing #{s}"
					     s.reinit!
					     reinit(s.id)
					     true
					 elsif s.has_sample?
					     if Roby::Log::Server.logger.debug?
						 Roby::Log::Server.debug "new sample for #{s} at #{s.current_time.to_hms}"
					     end
					     push(s.id, s.current_time, s.read)
					     true
					 end
			end
		    end
			
		    unless done_sth
			sleep(polling_timeout)
		    end
		end
	    rescue Interrupt
	    end

	    # Creates a new thread to send updates to +remote+
	    def pushing_loop(remote, queue)
		Thread.new do
		    begin
			loop do
			    calls = queue.get(false)
			    remote.demux(calls)
			    if calls.find { |m, _| m == :quit }
				break
			    end
			end
		    rescue Interrupt
		    rescue DRb::DRbConnError => e
			Server.warn "cannot communicate with #{remote.__drburi}. Assuming we are disconnected"

		    ensure
			synchronize do
			    # Remove all subscriptions for +remote+
			    subscriptions.each_value do |subscribed|
				subscribed.delete(remote)
			    end
			    queue, thread = connections.delete(remote)
			end
		    end
		end
	    end
	    private :pushing_loop

	    # New stream
	    def added_stream(stream)
		synchronize do
		    @streams << stream
		    connections.each_value do |queue, _|
			queue.push [:added_stream, stream.class.name, stream.id, stream.name, stream.type]
		    end
		end
	    end

	    # Stream +id+ has stopped
	    def removed_stream(id)
		synchronize do
		    found = false
		    @streams.delete_if { |s| found ||= (s.id == id) }
		    unless found
			raise ArgumentError, "no such stream"
		    end

		    connections.each_value do |queue, _|
			queue.push [:removed_stream, id]
		    end
		    subscriptions.delete(id)
		end
	    end

	    # Returns a set of Roby::Log::DataStream objects describing the
	    # available data sources on this stream
	    def streams
		synchronize do
		    @streams.dup
		end
	    end

	    # Make +remote+ subscribe to the stream identified by +id+. When
	    # new data is available, #push will be called on +remote+. The
	    # exact format of the pushed sample depends on the type of the
	    # stream
	    #
	    # If the stream stop existing (because it source has quit for
	    # instance), #removed_stream will be called on the remote object
	    def subscribe(id, remote)
		synchronize do
		    if s = @streams.find { |s| s.id == id }
			subscriptions[id] << remote
			if data = s.read_all
			    remote.init(id, data)
			end
		    else
			raise ArgumentError, "no such stream"
		    end
		end
	    end

	    # Rmoves a subscription of +remote+ on +id+
	    def unsubscribe(id, remote)
		synchronize do
		    if subscriptions.has_key?(id)
			subscriptions[id].delete(remote)
		    end
		end
	    end

	    # Reinitializes the stream +id+. It is used when a stream has
	    # been truncated (for instance when a log file has been restarted)
	    #
	    # This must be called in a synchronize { } block
	    def reinit(id)
		subscriptions[id].each do |remote|
		    queue, _ = connections[remote]
		    queue.push [:reinit, id]
		end
	    end
	    private :reinit

	    # Pushes a new sample on stream +id+
	    #
	    # This must be called in a synchronize { } block
	    def push(id, time, sample)
		if subscriptions.has_key?(id)
		    subscriptions[id].each do |remote|
			queue, _ = connections[remote]
			queue.push [:push, id, time, sample]
		    end
		end
	    end
	    private :push

	    def quit
		if @polling
		    @polling.raise Interrupt, "quitting"
		    @polling.join
		end

		connections.each_value do |queue, thread|
		    queue.push [:quit]
		    thread.join
		end
	    end
	end

	# This class manages a data stream which is present remotely. Data is sent
	# as-is over the network from a Server object to a Client object.
	class RemoteStream < DataStream
	    def initialize(stream_model, id, name, type)
		super(name, type)
		@id = id
		@stream_model = stream_model

		@data_file = Tempfile.new("remote_stream_#{name}_#{type}".gsub("/", "_"))
		@data_file.sync = true

		@mutex = Mutex.new
		@pending_samples = Array.new
	    end
	    def synchronize; @mutex.synchronize { yield } end

	    # The data file in which we save the data received so far
	    attr_reader :data_file
	    # The DataStream class of the remote stream. This is used for
	    # decoding
	    attr_reader :stream_model

	    def added_decoder(dec)
		synchronize do
		    Server.info "#{self} initializing #{dec}"
		    if data_file.stat.size == 0
			return
		    end

		    data_file.rewind
		    chunk_length = data_file.read(4).unpack("N").first
		    chunk = data_file.read(chunk_length)
		    init(chunk) do |sample|
			dec.process(sample)
		    end

		    while !data_file.eof?
			chunk_length = data_file.read(4).unpack("N").first
			chunk = data_file.read(chunk_length)
			dec.process(decode(sample))
		    end

		    display
		end
	    end

	    def reinit!
		data_file.truncate(0)
		@pending_samples.clear
		@current_time = nil

		super
	    end

	    # Called when new data is available
	    def push(time, data)
		Server.info "#{self} got #{data.size} bytes of data at #{time.to_hms}"
		synchronize do
		    @range[0] ||= time
		    @range[1] = time
		    @current_time ||= time

		    @pending_samples.unshift [time, data]
		    data_file << [data.size].pack("N") << data
		end
	    end

	    def current_time
		synchronize { @current_time }
	    end
	    
	    def next_time
		synchronize do
		    if has_sample?
			@pending_samples.first
		    end
		end
	    end

	    def range
		synchronize { super }
	    end

	    def has_sample?
		synchronize do
		    !@pending_samples.empty? 
		end
	    end

	    def read
		if reinit?
		    reinit!
		end

		@current_time, sample = @pending_samples.pop
		sample
	    end

	    def init(data, &block)
		Server.info "#{self} initializing with #{data.size} bytes of data"
		data_file << [data.size].pack("N") << data
		stream_model.init(data, &block)
	    end
	    def decode(data)
		stream_model.decode(data)
	    end
	end

	class Client
	    # The remote display server
	    attr_reader :server

	    def initialize(server)
		@server  = server
		@pending = Hash.new
		connect
	    end

	    def streams
		@streams.values
	    end

	    def added_stream(klass_name, id, name, type)
		@streams[id] = RemoteStream.new(constant(klass_name), id, name, type)
		super if defined? super
	    end
	    def removed_stream(id)
		@streams.delete(id)
		super if defined? super
	    end

	    attr_reader :last_update
	    MIN_DISPLAY_DURATION = 5
	    def demux(calls)
		calls.each do |args|
		    send(*args)
		end

		streams.each do |s|
		    while s.has_sample?
			s.synchronize do
			    s.advance
			end
		    end
		end

		sleep(0.5)
	    end

	    def subscribe(stream)
		@server.subscribe(stream.id, DRbObject.new(self))
	    end

	    def unsubscribe(stream)
		@server.unsubscribe(stream.id, DRbObject.new(self))
	    end

	    def init(id, data)
		s = @streams[id]
		Server.info "initializing #{s}"
		s.synchronize do
		    s.init(data) do |sample|
			s.decoders.each do |dec|
			    dec.process(sample)
			end
		    end
		end
	    end

	    def reinit(id)
		@streams[id].reinit = true
	    end

	    def push(id, time, data)
		@streams[id].push(time, data)
	    end

	    def connected?; !!@streams end
	    def connect
		if connected?
		    raise ArgumentError, "already connected"
		end

		@streams = Hash.new
		server.connect(DRbObject.new(self)).
		    each do |klass, id, name, type|
			added_stream(klass, id, name, type)
		    end

		ObjectSpace.define_finalizer(self, Client.remote_streams_finalizer(server, DRbObject.new(self)))
	    end

	    def self.remote_streams_finalizer(server, drb_object)
		Proc.new do
		    begin
			server.disconnect(drb_object)
		    rescue DRb::DRbConnError
		    rescue Exception => e
			STDERR.puts e.full_message
		    end
		end
	    end

	    def disconnect
		@streams = nil
		server.disconnect(DRbObject.new(self))
	    rescue DRb::DRbConnError
	    end

	    def quit
		@streams = nil
		@server  = nil
	    end
	end
    end
end

if $0 == __FILE__
    include Roby
    include Roby::Log

    # First find the available servers
    STDERR.puts "Finding available servers ..."
    DRb.start_service
    Server.enable_discovery 'localhost'
    sleep(0.5)
    Server.available_servers.each do |server|
	remote = RemoteStreams.new(server)
	puts "#{server.__drburi}:"
	remote.streams.each do |s|
	    puts "  #{s.name} [#{s.type}]"
	end
    end
end

