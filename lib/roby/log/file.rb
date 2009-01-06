require 'roby/log/logger'
require 'roby/distributed'
require 'tempfile'
require 'fileutils'

module Roby::Log
    class Logfile < DelegateClass(File)
	attr_reader :event_io
	attr_reader :index_io
	attr_reader :index_data
	attr_reader :basename
	def range
	    [Time.at(*index_data.first[:start]), 
		Time.at(*index_data.last[:start]) + index_data.last[:end]]
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

	    if !allow_old_format
		FileLogger.check_format(@event_io)
	    end

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
	    begin
		pos = nil
		loop do
		    pos = index_io.tell
		    length = index_io.read(4)
		    raise EOFError unless length
		    length = length.unpack("N").first
		    index_data << Marshal.load(index_io.read(length))
		end
	    rescue EOFError
		index_io.seek(pos, IO::SEEK_SET)
	    end

	    return if index_data.empty?
	end

        def valid_index?
            100.times do |i|
                break if i * 10 >= index_data.size
                index = index_data[i * 10]

                event_io.seek(index[:pos])
                cycle = begin
                    Marshal.load(event_io)
                rescue EOFError
                    return false
                rescue ArgumentError
                    return false
                end

                if cycle[-4] != :cycle_end ||
                    cycle[-1].first != index
                    return false
                end
            end
            true
        end

	def rewind
	    @event_io.rewind
	    Marshal.load(@event_io)
	    @index_io.rewind
	    @index_data.clear
	    update_index
	end

	def rebuild_index
	    STDOUT.puts "rebuilding index file for #{basename}"
	    @index_io.close if @index_io
	    @index_io = File.open("#{basename}-index.log", 'w+')
	    FileLogger.rebuild_index(@event_io, @index_io)
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
	# The current log format version
	FORMAT_VERSION = 3

	@dumped = Hash.new
	class << self
	    attr_reader :dumped
	end

	# The IO object for the event log
	attr_reader :event_log
	# The IO object for the index log
	attr_reader :index_log
	# The set of events for the current cycle. This is dumped only
	# when the +cycle_end+ event is received
	attr_reader :current_cycle
	# StringIO object on which we dump the data
	attr_reader :dump_io

	def initialize(basename)
	    @current_pos   = 0
	    @dump_io	   = StringIO.new('', 'w')
	    @current_cycle = Array.new
	    @event_log = File.open("#{basename}-events.log", 'w')
	    event_log.sync = true
	    FileLogger.write_header(@event_log)
	    @index_log = File.open("#{basename}-index.log", 'w')
	    index_log.sync = true
	end

	attr_accessor :stats_mode
	def splat?; false end
        def logs_message?(m)
	    m == :cycle_end || !stats_mode
        end

	def dump_method(m, time, args)
	    if m == :cycle_end || !stats_mode
		current_cycle << m << time.tv_sec << time.tv_usec << args
	    end
	    if m == :cycle_end
		info = args.first
		info[:pos] = event_log.tell
		info[:event_count] = current_cycle.size / 4
		Marshal.dump(current_cycle, event_log)

		dump_io.truncate(0)
		dump_io.seek(0)
		Marshal.dump(info, dump_io)
		index_log.write [dump_io.size].pack("N")
		index_log.write dump_io.string
		current_cycle.clear
	    end

	rescue 
            current_cycle.each_slice(4) do |m, sec, usec, args|
		unless (Marshal.dump(args) rescue nil)
                    args.each do |obj|
                        unless (Marshal.dump(obj) rescue nil)
                            puts "cannot dump the following object in #{m}(#{args.join(", ")}):"
                            pp obj
                        end
                    end
		end
            end
	end

	Roby::Log.each_hook do |klass, m|
	    define_method(m) { |time, args| dump_method(m, time, args) }
	end
	
	# Creates an index file for +event_log+ in +index_log+
	def self.rebuild_index(event_log, index_log)
	    event_log.rewind
	    # Skip the file header
	    Marshal.load(event_log)

	    current_pos = event_log.tell
	    dump_io	   = StringIO.new("", 'w')

	    loop do
		cycle = Marshal.load(event_log)
		info               = cycle.last.last
		info[:pos]         = current_pos
		info[:event_count] = cycle.size

		dump_io.truncate(0)
		dump_io.seek(0)
		Marshal.dump(info, dump_io)
		index_log.write [dump_io.size].pack("N")
		index_log.write dump_io.string

		current_pos = event_log.tell
	    end

	rescue EOFError
	ensure
	    event_log.rewind
	    index_log.rewind
	end


	def self.log_format(input)
	    input.rewind
	    format = begin
			 header = Marshal.load(input)
			 case header
			 when Hash: header[:log_format]
			 when Symbol
			     if Marshal.load(input).kind_of?(Array)
				 0
			     end
			 when Array
			     1 if header[-2] == :cycle_end
			 end
		     rescue
		     end

	    unless format
		raise "#{input.path} does not look like a Roby event log file"
	    end
	    format

	ensure
	    input.rewind
	end

	def self.check_format(input)
	    format = log_format(input)
	    if format < FORMAT_VERSION
		raise "this is an outdated format. Please run roby-log upgrade-format"
	    elsif format > FORMAT_VERSION
		raise "this is an unknown format version #{format}: expected #{FORMAT_VERSION}. This file can be read only by newest version of Roby"
	    end
	end

	def self.write_header(io)
	    header = { :log_format => FORMAT_VERSION }
	    Marshal.dump(header, io)
	end

	def self.from_format_0(input, output)
	    current_cycle = []
	    while !input.eof?
		m    = Marshal.load(input)
		args = Marshal.load(input)

		current_cycle << m << args
		if m == :cycle_end
		    Marshal.dump(current_cycle, output)
		    current_cycle.clear
		end
	    end

	    unless current_cycle.empty?
		Marshal.dump(current_cycle, output)
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
	    input_stream = EventStream.new("input", Logfile.new(input, true))
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

		    Marshal.dump(new_cycle, output)
		rescue Exception => e
		    STDERR.puts "dropped cycle because of the following error:"
		    STDERR.puts "  #{e.full_message}"
		end
	    end
	end

	def self.to_new_format(file, into = file)
	    input = File.open(file)
	    log_format = self.log_format(input)

	    if log_format == FORMAT_VERSION
		STDERR.puts "#{file} is already at format #{log_format}"
	    else
		if into =~ /-events\.log$/
		    into = $`
		end
		STDERR.puts "upgrading #{file} from format #{log_format} into #{into}"

		input.rewind
		Tempfile.open('roby_to_new_format') do |output|
		    write_header(output)
		    send("from_format_#{log_format}", input, output)
		    output.flush

		    input.close
		    FileUtils.cp output.path, "#{into}-events.log"
		end

		File.open("#{into}-events.log") do |event_log|
		    File.open("#{into}-index.log", 'w') do |index_log|
			puts "rebuilding index file for #{into}"
			rebuild_index(event_log, index_log)
		    end
		end
	    end

	ensure
	    input.close if input && !input.closed?
	end
    end
end

