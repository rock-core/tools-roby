require 'roby/log/data_stream'

module Roby
    module Log
	# This class is a logger-compatible interface which read event and index logs,
	# and may rebuild the task and event graphs from the marshalled events
	# that are saved using for instance FileLogger
	class EventStream < DataStream
	    def splat?; true end

	    # The IO object of the event log
	    attr_reader :event_log
	    # The IO object of the index log
	    attr_reader :index_log
	    # The data from +index_log+ loaded so far
	    attr_reader :index_data

	    # The index of the currently displayed cycle in +index_data+
	    attr_reader :current_cycle
	    # A [min, max] array of the minimum and maximum times for this
	    # stream
	    attr_reader :range

	    def initialize(basename)
		@event_log = Roby::Log.open("#{basename}-events.log")
		begin
		    @index_log  = File.open("#{basename}-index.log")
		rescue Errno::ENOENT
		    Roby.warn "rebuilding index file in #{basename}-index.log"
		    @index_log = File.open("#{basename}-index.log", "w+")
		    FileLogger.rebuild_index(@event_log, @index_log)
		end

		super(basename, 'roby-events')
		@index_data = Array.new
		reinit!
	    end

	    def rebuild_index
		index_log.rewind
		index_data.clear
		update_index
	    end

	    # Reads as much data as possible from the index file and decodes it
	    # into the #index_data array.
	    def update_index
		begin
		    pos = nil
		    loop do
			pos = index_log.tell
			index_data << Marshal.load(index_log)
		    end
		rescue EOFError
		    index_log.seek(pos, IO::SEEK_SET)
		end

		return if index_data.empty?
		@range = [index_data.first[:start], index_data.last[:end]]
	    end

	    # True if the stream has been reinitialized
	    def reinit?
		@reinit ||= (!index_data.empty? && event_log.stat.size < index_data.last[:pos])
	    end

	    # Reinitializes the stream
	    def reinit!
		@current_cycle = 0
		prepare_seek(nil)

		super
	    end

	    # True if there is at least one sample available
	    def has_sample?
		update_index
		!index_data.empty? && (index_data.last[:pos] > event_log.tell)
	    end

	    # Seek the data stream to the specified time.
	    def prepare_seek(time)
		if !time || !current_time || time < current_time
		    clear

		    event_log.rewind
		    # Re-read the index information
		    index_data.clear
		    index_log.rewind
		    update_index
		end
	    end
	    
	    # The current time
	    def current_time
		return if index_data.empty?
		if index_data.size == current_cycle + 1
		    index_data[current_cycle][:end]
		else
		    index_data[current_cycle][:start]
		end
	    end

	    # The time we will reach when the next sample is processed
	    def next_time
		return if index_data.empty?
		if index_data.size > current_cycle + 1
		    index_data[current_cycle + 1][:start]
		end
	    end

	    # Reads a sample of data and returns it. It will be fed to
	    # decoders' #decode method.
	    #
	    # In this stream, this is the chunk of the marshalled file which
	    # corresponds to a cycle
	    def read
		if reinit?
		    reinit!
		end

		start_pos = index_data[current_cycle][:pos]
		end_pos   = if index_data.size > current_cycle + 1
				index_data[current_cycle + 1][:pos]
			    else
				event_log.stat.size
			    end

		event_log.seek(start_pos)
		event_log.read(end_pos - start_pos)

	    ensure
		@current_cycle += 1
	    end

	    # Read all data read so far in a format suitable to feed to
	    # #init_stream on the decoding side
	    def read_all
		end_pos   = if index_data.size > current_cycle + 1
				index_data[current_cycle + 1][:pos]
			    else
				event_log.stat.size
			    end
		event_log.seek(0)
		event_log.read(end_pos)
	    end
	end
    end
end

