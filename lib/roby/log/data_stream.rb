require 'roby/log'
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

	def self.open(basename)
	    stream = new(basename)
	    stream.open

	    if block_given?
		begin
		    yield(stream)
		ensure
		    stream.logfile.close
		end
	    else
		stream
	    end
	end


	def initialize(name, type)
	    @id   = object_id
	    @name = name
	    @type = type
	    @range = [nil, nil]

	    @decoders = []
	end

	def to_s; "#{name} [#{type}]" end
	def open; end
	def close; end

	def has_sample?; false end
	attr_predicate :reinit, true
	def reinit?;  end
	def reinit!
	    @range  = [nil, nil]
	    @reinit = false

	    clear
	end
	def read_all; end

	def read_and_decode
	    self.class.decode(read)
	end

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

	# Reuse or creates a decoder of the given class for this data
	# stream
	def decoder(klass)
	    if dec = decoders.find { |d| d.kind_of?(klass) }
		dec
	    else
		decoders << (dec = klass.new(name))
		dec.stream = self
		added_decoder(dec)
		dec
	    end
	end

	def added_decoder(dec)
	    super if defined? super
	end

	# Do a read and decode the data
        #
        # It returns false if no decoders have found interesting updates in the
        # decoded data, and true otherwise. The method relies on the decoder's
        # #process method to return true/false when required.
        #
        # See DataDecoder#process
        def advance
	    data = decode(read)
	    !decoders.find_all do |dec|
		dec.process(data)
	    end.empty?
	end

	def init(data)
	    self.class.init(data)
	end
	def decode(data)
	    self.class.decode(data)
	end

	def clear_integrated
	    decoders.each do |decoder|
		decoder.clear_integrated
	    end
	end

	# Update the displays
        #
        # It returns false if all decoders have reported that no display update
        # was required, and true otherwise. The method relies on the decoder's
        # #display method to return true/false when required.
        #
        # See DataDecoder#display
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

    # In the data flow model we're using, a data decoder gets data from a
    # DataStream object and builds a representation that can be used by
    # displays.
    class DataDecoder
	# The set of displays attached to this decoder
	attr_reader :displays
        # The decoder name
	attr_reader :name

        # The DataStream object we're getting our data from
	attr_accessor :stream

	def initialize(name)
	    @name = name
	    @displays = [] 
	end

        # Clear the stream data
	def clear
	    displays.each { |d| d.clear }
	end

	def clear_integrated
	    displays.each do |display|
		display.clear_integrated if display.respond_to?(:clear_integrated)
	    end
	end

	# Updates the displays that are associated with this decoder. Returns
        # true if one of the displays have been changed, and false otherwise.
        #
        # It relies on the display's #update method to return true if something
        # has changed on the display and false otherwise.
	def display
	    !displays.find_all do |display| 
		display.update
	    end.empty?
	end
    end

    # This module gets mixed-in the display classes. It creates the necessary
    # stream => decoder => display link, reusing (if possible) a decoder that
    # already exists.
    #
    # One should use it that way:
    #
    # class Display
    #   include DataDisplay
    #   decoder DecoderClass
    # end
    #
    # Then, one can do
    #   display = Display.new
    #   display.stream = data_stream
    #
    # and leave the rest to the DataDisplay implementation.
    module DataDisplay
	module ClassExtension
	    def decoder(new_type = nil)
		if new_type
		    @decoder_class = new_type
		else
		    @decoder_class
		end
	    end
	end

        # The decoder object. That object gets data from a DataStream object and
        # decodes it into the format required by the display.
        #
        # Examples: PlanRebuilder
	attr_reader :decoder
	attr_reader :main

        # The configuration UI object. Usually a subclass of Qt::Widget
	attr_accessor :config_ui


	def splat? #:nodoc:
            true
        end

        # Sets the data stream that this display listens to. It creates or gets
        # the decoder that is necessary between the raw stream and the display
	def stream=(data_stream)
	    if decoder
		clear
	    end

	    @decoder = data_stream.decoder(self.class.decoder)
	    decoder.displays << self
	end

	def clear; end
    end
end

