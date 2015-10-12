require 'tempfile'
require 'fileutils'

module Roby::Log
    class Logfile < DelegateClass(File)
	# The current log format version
	FORMAT_VERSION = 4

	attr_reader :event_io
	attr_reader :index_io
	attr_reader :index_data
	attr_reader :basename

        MAGIC_CODE = "ROBYLOG"
        PROLOGUE_SIZE = MAGIC_CODE.size + 4

        class TruncatedFileError < EOFError; end
        class InvalidFileError < RuntimeError; end


        def self.write_prologue(io)
            io.write(MAGIC_CODE)
            io.write([FORMAT_VERSION].pack("I"))
        end

	def self.write_header(io, options = Hash.new)
            write_prologue(io)
	    dump(options, io)
	end

        def self.read_prologue(io)
            magic = io.read(MAGIC_CODE.size)
            if magic != MAGIC_CODE
                raise InvalidFileError, "no magic code at beginning of file"
            end

            log_format = io.read(4).unpack('I').first
            validate_format(log_format)

        rescue Exception => e
            io.rewind
            if format = guess_log_format(io)
                validate_format(format)
            else
                raise
            end
        end

	def self.guess_log_format(input)
	    input.rewind

            begin
                magic = input.read(Logfile::MAGIC_CODE.size)
                if magic == Logfile::MAGIC_CODE
                    format = input.read(4).unpack("I").first
                else
                    input.rewind
                    header = Marshal.load(input)
                    case header
                    when Hash then format = header[:log_format]
                    when Symbol
                        if Marshal.load(input).kind_of?(Array)
                            format = 0
                        end
                    when Array
                        if header[-2] == :cycle_end
                            format = 1 
                        end
                    end
                end
            rescue
            end

	    format

	ensure
	    input.rewind
	end

	def self.validate_format(format)
	    if format < FORMAT_VERSION
		raise "this is an outdated format. Please run roby-log upgrade-format"
	    elsif format > FORMAT_VERSION
		raise "this is an unknown format version #{format}: expected #{FORMAT_VERSION}. This file can be read only by newest version of Roby"
	    end
	end

        # Reads the header from the log file and returns the logfile's option
        # hash
        def self.read_header(io)
            read_prologue(io)
            self.load_one_chunk(io)
        end

        def read_header
            Logfile.read_header(@event_io)
        end

        def self.dump(object, io, buffer_io = nil)
            if buffer_io
		buffer_io.truncate(0)
		buffer_io.seek(0)
                Marshal.dump(object, buffer_io)
                io.write([buffer_io.size].pack("I"))
                io.write(buffer_io.string)
            else
                buffer = Marshal.dump(object)
                io.write([buffer.size].pack("I"))
                io.write(buffer)
            end
        end

        def dump(object, buffer_io = nil)
            Logfile.dump(object, @event_io, buffer_io)
        end

        # Load a chunk of data from an event file.  +buffer+, if given, must be
        # a String object that will be used as intermediate buffer in the
        # process
        def self.load_one_chunk(io)
            data_size = io.read(4)
            if !data_size
                raise TruncatedFileError
            end

            data_size = data_size.unpack("I").first
            buffer = io.read(data_size)
            if !buffer || buffer.size < data_size
                raise TruncatedFileError
            end
            Marshal.load_with_missing_constants(buffer)
        end

        def load_one_chunk
            Logfile.load_one_chunk(@event_io)
        end

        def self.process_options_hash(options_hash)
            if options_hash[:plugins]
                options_hash[:plugins].each do |plugin_name|
                    begin
                        Roby.app.using plugin_name
                    rescue ArgumentError => e
                        Roby.warn "the log file mentions the #{plugin_name} plugin, but it is not available on this system. Some information might not be displayed"
                    end
                end
            end
        end

	
	# Creates an index file for +event_log+ in +index_log+
	def self.rebuild_index(event_log, index_log)
	    event_log.rewind
            event_log.seek(0, IO::SEEK_END)
            end_pos = event_log.tell
	    event_log.rewind

            read_header(event_log)

	    current_pos = event_log.tell
	    dump_io	= StringIO.new("", 'w')

	    loop do
		cycle = self.load_one_chunk(event_log)
		info  = cycle.last.last
                info[:pos] = current_pos

                if block_given?
                    yield(Float(event_log.tell) / end_pos)
                end

		dump(info, index_log, dump_io)
		current_pos = event_log.tell
	    end

	rescue EOFError
	ensure
	    event_log.rewind
	    index_log.rewind
	end

	def range
            if !index_data.empty?
                [Time.at(*index_data.first[:start]), 
                    Time.at(*index_data.last[:start]) + index_data.last[:end]]
            end
	end

	def initialize(file, allow_old_format = false, force_rebuild_index = false)
	    @event_io = if file.respond_to?(:to_str)
			    @basename = if file =~ /-events\.log$/ then $`
					else file
					end

			    File.open("#{basename}-events.log")
			else
			    @basename = file.path.gsub(/-events\.log$/, '')
			    file
			end

            @event_io.rewind
            options_hash = read_header
            Logfile.process_options_hash(options_hash)

	    index_path = "#{basename}-index.log"
	    if force_rebuild_index || !File.file?(index_path)
		rebuild_index
	    else
		@index_io = File.open(index_path)
		if @index_io.stat.size == 0
		    rebuild_index
		end
	    end

	    super(@event_io)

	    @index_data = Array.new
            begin
                rewind
            rescue ArgumentError, EOFError
                rebuild_index
                rewind
            end

            if !valid_index?
                rebuild_index
                rewind
            end
	end

	# Reads as much index data as possible
	def update_index
            pos = index_io.tell
            index_io.seek(0, IO::SEEK_END)
            end_pos = index_io.tell
            index_io.seek(pos, IO::SEEK_SET)

	    begin
		pos = nil
		loop do
		    pos = index_io.tell
                    yield(Float(pos) / end_pos) if block_given?

                    cycle = Logfile.load_one_chunk(index_io)
		    index_data << cycle
		end
	    rescue EOFError
		index_io.seek(pos, IO::SEEK_SET)
	    end

        rescue Exception => e
            STDERR.puts e
	end

        def valid_index?
            100.times do |i|
                break if i * 10 >= index_data.size
                index = index_data[i * 10]

                event_io.seek(index[:pos])
                cycle = begin
                    self.load_one_chunk
                rescue EOFError
                    return false
                rescue ArgumentError
                    return false
                end

                stats = cycle.last[0].dup
                stats.delete(:state)
                index = index.dup
                index.delete(:state)
                if stats != index
                    return false
                end
            end
            true
        end

	def rewind
	    @event_io.rewind
            read_header
	    @index_io.rewind
	    @index_data.clear

            STDERR.print "loading index file"
            STDERR.flush

	    update_index do |progress|
                STDERR.print "\rloading index file (#{Integer(progress * 100)}%)"
                STDERR.flush
            end
            STDERR.puts
	end

	def rebuild_index
	    STDERR.print "rebuilding index file for #{basename}"

	    @index_io.close if @index_io
	    @index_io = File.open("#{basename}-index.log", 'w+')
	    Logfile.rebuild_index(@event_io, @index_io) do |progress|
                STDERR.print "\rrebuilding index file for #{basename} (#{Integer(progress * 100)}%)"
            end
            STDERR.puts
	end

	def self.open(path)
	    io = new(path)
	    if block_given?
		begin
		    yield(io)
		ensure
		    io.close unless io.closed?
		end
	    else
		io
	    end
	end
    end

    # A logger object which marshals all available events in two files. The
    # event log is the full log, the index log contains only the timings given
    # to ExecutionEngine#cycle_end, along with the corresponding position in the event
    # log file.
    #
    # You can use FileLogger.replay(io) to send the events back into the
    # logging system (using Log.log), for instance to feed an offline display
    class FileLogger
	# The IO object for the event log
	attr_reader :event_log
	# The IO object for the index log
	attr_reader :index_log
	# The set of events for the current cycle. This is dumped only
	# when the +cycle_end+ event is received
	attr_reader :current_cycle
	# StringIO object on which we dump the data
	attr_reader :dump_io

	def initialize(basename, options)
	    @current_pos   = 0
	    @dump_io	   = StringIO.new('', 'w')
	    @current_cycle = Array.new
	    @event_log = File.open("#{basename}-events.log", 'w')
	    event_log.sync = true
	    Logfile.write_header(@event_log, options)
	    @index_log = File.open("#{basename}-index.log", 'w')
	    index_log.sync = true
	end

	attr_accessor :stats_mode
	def splat?; false end
        def logs_message?(m)
	    m == :cycle_end || !stats_mode
        end

        def close
            dump_method(:cycle_end, Time.now, [])
            @event_log.close
            @index_log.close
        end

	def dump_method(m, time, args)
	    if m == :cycle_end || !stats_mode
		current_cycle << m << time.tv_sec << time.tv_usec << args
	    end
	    if m == :cycle_end
		info = args.first
		info[:pos] = event_log.tell
		info[:event_count] = current_cycle.size / 4

		Logfile.dump(current_cycle, event_log, dump_io)
		Logfile.dump(info, index_log, dump_io)
		current_cycle.clear
	    end

	rescue 
            current_cycle.each_slice(4) do |m, sec, usec, args|
                begin
                    Marshal.dump(args)
                rescue Exception => e
                    Roby::Log.fatal "failed to dump cycle info: #{e}"
                    args.each do |obj|
                        begin
                            Marshal.dump(obj)
                        rescue Exception => e
                            Roby::Log.fatal "cannot dump #{obj}"
                            Roby::Log.fatal e.to_s
                            obj, exception = self.class.find_invalid_marshalling_object(obj)
                            if obj
                                Roby::Log.fatal "  it seems that #{obj} can't be marshalled"
                                Roby::Log.fatal "    #{exception.class}: #{exception.message}"
                            end
                        end
                    end
		end
            end
	end

        def self.find_invalid_marshalling_object(obj, stack = Set.new)
            if stack.include?(obj)
                return
            end
            stack << obj

            case obj
            when Enumerable
                obj.each do |value|
		    invalid, exception = find_invalid_marshalling_object(value, stack)
                    if invalid
                        return "#{invalid}, []", exception
                    end
                end
            end

            # Generic check for instance variables
            obj.instance_variables.each do |iv|
                value = obj.instance_variable_get(iv)
		invalid, exception = find_invalid_marshalling_object(value, stack)
                if invalid
                    return "#{invalid}, #{iv}", exception
                end
            end

            begin
                Marshal.dump(obj)
                nil
            rescue Exception => e
                begin
                    return "#{obj} (#{obj.class})", e
                rescue Exception
                    return "-- cannot display object, #to_s raised -- (#{obj.class})", e
                end
            end
        end

        def self.define_hook(m)
	    define_method(m) { |time, args| dump_method(m, time, args) }
	end

        def dump(object)
            Logfile.dump(object, event_io)
        end

	def self.from_format_0(input, output)
	    current_cycle = []
	    while !input.eof?
		m    = Marshal.load(input)
		args = Marshal.load(input)

		current_cycle << m << args
		if m == :cycle_end
		    dump(current_cycle, output)
		    current_cycle.clear
		end
	    end

	    unless current_cycle.empty?
		dump(current_cycle, output)
	    end
	end

	def self.from_format_1(input, output)
	    # The only difference between v1 and v2 is the header. Just copy
	    # data from input to output
	    output.write(input.read)
	end

	def self.from_format_2(input, output)
	    # In format 3, we did two things:
	    #   * changed the way exceptions were dumped: instead of relying on
	    #     DRbRemoteError, we are now using DRobyModel
	    #   * stopped dumping Time objects and instead marshalled tv_sec
	    #     and tv_usec directly
	    Exception::DRoby.class_eval do
		def self._load(str)
		    Marshal.load(str)
		end
	    end

	    new_cycle = []
	    input_stream = EventStream.new("input", FileLogger.new(input, true))
	    while !input.eof?
		new_cycle.clear
		begin
		    m_data = input_stream.read
		    cycle_data = Marshal.load(m_data)
		    cycle_data.each_slice(2) do |m, args|
			time = args.shift
			new_cycle << m << time.tv_sec << time.tv_usec << args
		    end

		    stats   = new_cycle.last.first
		    reftime = stats[:start]
		    stats[:start] = [reftime.tv_sec, reftime.tv_usec]
		    new_cycle.last[0] = stats.inject(Hash.new) do |new_stats, (name, value)|
			new_stats[name] = if value.kind_of?(Time) then value - reftime
					  else value
					  end
			new_stats
		    end

		    dump(new_cycle, output)
		rescue Exception => e
		    STDERR.puts "dropped cycle because of the following error:"
		    STDERR.puts "  #{e.full_message}"
		end
	    end
	end

        def self.from_format_3(input, output)
            # Header format changed. Read the old one and add the new one
            header = Marshal.load(input)
            Logfile.dump(header, output)

            # In format 4, every marshal'ed structure is prefixed with the size
            # of the block
            while !input.eof?
                start_pos = input.tell
                Marshal.load_with_missing_constants(input)
                length = input.tell - start_pos

                # Don't take risks by re-dumping the object. Simply copy the raw
                # data with added size in front
                size = [length].pack("I")
                output.write(size)
                input.seek(start_pos)
                output.write(input.read(length))
            end
        end

	def self.to_new_format(file, into = file)
	    input = File.open(file)
	    log_format = Logfile.guess_log_format(input)
            if !log_format
                raise InvalidFileError, "#{file} does not seem to be a Roby log file"
            end

	    if log_format == Logfile::FORMAT_VERSION
		STDERR.puts "#{file} is already at format #{log_format}"
	    else
		if into =~ /-events\.log$/
		    into = $`
		end
		STDERR.puts "upgrading #{file} from format #{log_format} into #{into}"

		input.rewind
		Tempfile.open('roby_to_new_format') do |output|
		    Logfile.write_prologue(output)
		    send("from_format_#{log_format}", input, output)
		    output.flush

		    input.close
		    FileUtils.cp output.path, "#{into}-events.log"
		end

		File.open("#{into}-events.log") do |event_log|
		    File.open("#{into}-index.log", 'w') do |index_log|
			puts "rebuilding index file for #{into}"
			Logfile.rebuild_index(event_log, index_log)
		    end
		end
	    end

	ensure
	    input.close if input && !input.closed?
	end
    end

    self.register_generic_logger(FileLogger)
end

