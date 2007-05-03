module Roby::Log
    # == Displaying log data
    #
    # Data display is done in three objects:
    # * a DataStream object which is the data source itself. It gives
    #   information about available samples, time of samples and extracts raw
    #   data. An example of data stream is the EventStream object which reads
    #   Roby's event logs, returning one cycle worth of data at a time.
    # * a DataDecoder object which takes the raw data returned by a DataStream
    #   object and turns it into a more usable representation. For instance, the PlanBuilder
    #   decoder takes an event stream from an EventStream object and rebuilds a plan-like
    #   structure from it.
    # * a display which takes its information from the decoder. The RelationDisplay displays
    #   the information included in the PlanRebuilder decoder and displays it as a graph.
    class DataStream
	# The stream ID, which has to be unique on a single Roby core
	attr_reader :id
	# The stream name. A [name, type] has to be globally unique
	attr_reader :name
	# The stream type, as a string.
	attr_reader :type

	def initialize(name, type)
	    @id   = object_id
	    @name = name
	    @type = type
	    @range = [nil, nil]

	    @decoders = []
	end

	def to_s; "#{name} [#{type}]" end

	def has_sample?; false end
	def read_all; end

	# The [min, max] range of available samples. Initially
	# [nil, nil]
	attr_reader :range

	# The set of decoders attached to this stream
	attr_reader :decoders

	def clear
	    decoders.each { |dec| dec.clear }
	end

	# True if there is at least one display attached to this data stream
	def displayed?
	    decoders.any? do |dec|
		!dec.displays.empty?
	    end
	end

	# Reuse or creates a decoder of the given class for this data stream
	def decoder(klass)
	    if dec = decoders.find { |d| d.kind_of?(klass) }
		dec
	    else
		decoders << (dec = klass.new)
		added_decoder(dec)
		dec
	    end
	end

	def added_decoder(dec)
	    super if defined? super
	end

	# Read the next sample and feed it to the decoders
	def advance
	    data = read
	    decoders.each do |dec|
		dec.decode(data)
	    end
	end

	# Update the displays
	def display
	    decoders.each do |decoder|
		decoder.display
	    end
	end

	def ==(other)
	    other.kind_of?(DataStream) &&
		name == other.name &&
		type == other.type
	end
	def eql?(other); self == other end
	def hash; [name, type].hash end
    end

    class DataDecoder
	# The set of displays attached to this decoder
	attr_reader :displays

	def initialize; @displays = [] end

	def clear
	    displays.each { |d| d.clear }
	end

	# Update the display to the current state of the decoder
	def display
	    displays.each do |display| 
		display.update
	    end
	end
    end
end

