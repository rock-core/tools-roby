require 'roby/test/distributed'
require 'roby/log/server'

class TC_LogServer < Minitest::Test
    include Roby::Distributed::Test
    include Roby::Log

    def test_discovery(remote = nil)
	recursive = !remote
	remote ||= remote_server do
	    def display_server
		unless @display_server
		    @display_server = Log::Server.new
		    timings = DataStream.new 'robot', 'roby-timings'
		    @display_server.added_stream(timings)
		end
		DRbObject.new(@display_server)
	    end
	end

	remote_display = remote.display_server

	Log::Server.enable_discovery 'localhost'
	assert_raises(ArgumentError) { Log::Server.enable_discovery 'localhost' }
	sleep(0.5)
	assert_equal([remote_display], Log::Server.available_servers)

	Log::Server.disable_discovery
	if recursive
	    test_discovery(remote)
	end
    end

    def test_connection(remote = nil)
	recursive = !remote
	remote ||= remote_server do
	    attr_reader :timings, :events
	    def display_server
		unless @display_server
		    @display_server = Log::Server.new

		    @timings = DataStream.new 'robot', 'roby-timings'
		    @display_server.added_stream(timings)
		end
		DRbObject.new(@display_server)
	    end
	    def timings_id; timings.id end
	    def events_id; events.id end
	    def add_stream
		@events = DataStream.new 'robot', 'roby-events'
		@display_server.added_stream(events)
		nil
	    end
	    def remove_stream
		@display_server.removed_stream(events.id)
		nil
	    end
	    def quit
		@display_server.quit
		nil
	    end
	end

	display_server = remote.display_server
	source = Log::Client.new(display_server)
	assert_equal([[remote.timings_id, 'robot', 'roby-timings']], 
		     source.streams.map { |s| [s.id, s.name, s.type] })
	assert(source.connected?)

	remote.add_stream
	sleep(0.5)
	assert_equal([[remote.timings_id, 'robot', 'roby-timings'], [remote.events_id, 'robot', 'roby-events']].to_set, 
		     source.streams.map { |s| [s.id, s.name, s.type] }.to_set)

	remote.remove_stream
	sleep(0.5)
	assert_equal([['robot', 'roby-timings']], source.streams.map { |s| [s.name, s.type] })

	source.disconnect
	remote.add_stream
	sleep(0.5)
	assert(!source.connected?)

	# try reconnection ...
	if recursive
	    remote.remove_stream
	    test_connection(remote)
	else
	    source.connect
	    assert_equal([['robot', 'roby-timings'], ['robot', 'roby-events']].to_set, 
			 source.streams.map { |s| [s.name, s.type] }.to_set)

	    # ... or check what happens if the remote server quits
	    remote.quit
	    sleep(0.5)
	    assert(!source.connected?)
	end
    end

    def test_subscription
	remote = remote_server do
	    attr_reader :timings, :events
	    def display_server
		unless @display_server
		    @display_server = Log::Server.new
		    @timings = DataStream.new 'robot', 'roby-timings'
		    @display_server.added_stream(timings)
		end
		DRbObject.new(@display_server)
	    end
	    def add_sample
		@display_server.push(timings.id, Time.now, 42)
	    end
	end

	display_server = remote.display_server
	source = Log::Client.new(display_server)
	source.subscribe(stream = source.streams.first)

	remote.add_sample
	sleep(0.5)
	stream = source.streams.find { |s| s.id == stream.id }
	assert(stream.has_sample?)
	assert_equal(42, stream.read, source.streams)
	assert(!stream.has_sample?)
	
	source.unsubscribe(stream)
	remote.add_sample
	sleep(0.5)
    end
end

