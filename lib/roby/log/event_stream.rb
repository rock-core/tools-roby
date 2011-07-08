module Roby
    module LogReplay
	# This class is a logger-compatible interface which read event and index logs,
	# and may rebuild the task and event graphs from the marshalled events
	# that are saved using for instance FileLogger
	class EventFileStream
	    # The event log file
	    attr_reader :logfile
	    # The index of the currently displayed cycle in +index_data+
	    attr_reader :current_cycle
            # The index of the first non-empty cycle
            attr_reader :start_cycle
	    # A [min, max] array of the minimum and maximum times for this
	    # stream
	    def range
                if range = logfile.range
                    [start_time, logfile.range.last]
                end
            end

            def self.open(filename)
                stream = EventFileStream.new
                stream.open(filename)
                stream
            end

	    def open(filename)
                @logfile = Roby::Log.open(filename)
		find_start_cycle
		self
	    end

            def find_start_cycle
                start_cycle = 0
                while start_cycle < index_data.size && index_data[start_cycle][:event_count] == 4
                    start_cycle += 1
                end
                @start_cycle   = start_cycle
		@current_cycle = start_cycle
            end

	    def close; @logfile.close end

	    def index_data; logfile.index_data end

	    # True if the stream has been reinitialized
	    def reinit?
		@reinit ||= (!index_data.empty? && logfile.stat.size < index_data.last[:pos])
	    end

	    # Reinitializes the stream
	    def reinit!
		rewind
                find_start_cycle
            end

	    # True if there is at least one sample available
	    def has_sample?
		logfile.update_index
		!index_data.empty? && (index_data.last[:pos] > logfile.tell)
	    end

            # Returns at the beginning of the stream (if the stream is seekable)
            def rewind
                @current_time  = nil
                @current_cycle = start_cycle
                logfile.rewind
            end

	    # Called before seeking to a specific time
	    def prepare_seek(time)
		if !time || !current_time || time < current_time
                    rewind
		end
	    end

            def seek_to_cycle(cycle)
                @current_cycle = cycle
            end

            # The time of the earliest sample in the stream
	    def start_time
		return if start_cycle == index_data.size
		Time.at(*index_data[start_cycle][:start])
	    end
	    
	    # The time of the last returned sample
	    def current_time
		return if index_data.empty?
		time = Time.at(*index_data[current_cycle][:start])
		if index_data.size == current_cycle + 1
		    time += index_data[current_cycle][:end]
		end
		time
	    end

	    # The time we will reach when the next sample is processed
	    def next_time
		return if index_data.empty?
		if index_data.size > current_cycle + 1
		    Time.at(*index_data[current_cycle + 1][:start])
		end
	    end

            # Returns true if there is no more data available
            def eof?
                index_data.size == current_cycle + 1
            end

	    # Reads a sample of data and returns it
            #
            # In Roby, the returned sample is an array which contains all the
            # logged information for one cycle.
	    def read
		if reinit?
		    reinit!
		end

                if current_cycle >= index_data.size
                    return
                end

		start_pos = index_data[current_cycle][:pos]
		logfile.seek(start_pos)
                data_size = logfile.read(4).unpack("I").first
		Marshal.load_with_missing_constants(logfile.read(data_size))

	    ensure
		@current_cycle += 1
	    end
	end
    end
end

