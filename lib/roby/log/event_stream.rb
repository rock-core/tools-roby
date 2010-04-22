require 'roby/log/data_stream'

module Roby
    module LogReplay
	# This class is a logger-compatible interface which read event and index logs,
	# and may rebuild the task and event graphs from the marshalled events
	# that are saved using for instance FileLogger
	class EventStream < DataStream
	    def splat?; true end

	    # The event log
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

	    def initialize(basename, file = nil)
		super(basename, "roby-events")
		if file
		    @logfile = file
		    reinit!
		end
	    end
	    def open
		@logfile = Roby::Log.open(name)
		reinit!
		self
	    end
	    def close; @logfile.close end

	    def index_data; logfile.index_data end

	    # True if the stream has been reinitialized
	    def reinit?
		@reinit ||= (!index_data.empty? && logfile.stat.size < index_data.last[:pos])
	    end

	    # Reinitializes the stream
	    def reinit!
		prepare_seek(nil)

		super

                start_cycle = 0
                while start_cycle < index_data.size && index_data[start_cycle][:event_count] == 4
                    start_cycle += 1
                end
                @start_cycle   = start_cycle
		@current_cycle = start_cycle
            end

	    # True if there is at least one sample available
	    def has_sample?
		logfile.update_index
		!index_data.empty? && (index_data.last[:pos] > logfile.tell)
	    end

	    # Seek the data stream to the specified time.
	    def prepare_seek(time)
		if !time || !current_time || time < current_time
		    clear

		    @current_time  = nil
		    @current_cycle = start_cycle
		    logfile.rewind
		end
	    end

	    def start_time
		return if start_cycle == index_data.size
		Time.at(*index_data[start_cycle][:start])
	    end
	    
	    # The current time
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

	    # Reads a sample of data and returns it. It will be fed to
	    # decoders' #decode method.
	    #
	    # In this stream, this is the chunk of the marshalled file which
	    # corresponds to a cycle
	    def read
		if reinit?
		    reinit!
		end

                if current_cycle >= index_data.size
                    return
                end

		start_pos = index_data[current_cycle][:pos]
		end_pos   = if index_data.size > current_cycle + 1
				index_data[current_cycle + 1][:pos]
			    else
				logfile.stat.size
			    end

		logfile.seek(start_pos)
		logfile.read(end_pos - start_pos)

	    ensure
		@current_cycle += 1
	    end

	    # Unmarshalls a set of data returned by #read_all and yield
	    # each sample that should be fed to the decoders
	    def self.init(data)
		io = StringIO.new(data)
		while !io.eof?
		    yield(Marshal.load(io))
		end
	    rescue EOFError
	    end

	    # Unmarshalls one cycle of data returned by #read
            #
            # In the case of the event stream, this is one array dumped with
            # Marshal.dump
	    def self.decode(data)
		Marshal.load(data)
	    end

	    # Read all data read so far in a format suitable to feed to
	    # #init_stream on the decoding side
	    def read_all
		end_pos   = if index_data.size > current_cycle + 1
				index_data[current_cycle + 1][:pos]
			    else
				logfile.stat.size
			    end
		logfile.rewind
		logfile.read(end_pos)
	    end
	end
    end
end

