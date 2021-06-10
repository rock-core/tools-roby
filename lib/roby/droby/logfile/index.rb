# frozen_string_literal: true

require "roby/droby/logfile/reader"

module Roby
    module DRoby
        module Logfile
            class Index
                # Creates an index file for +event_log+ in +index_log+
                def self.rebuild(event_io, index_io)
                    stat = File.stat(event_io.path)
                    event_log = Reader.new(event_io)

                    write_header(index_io, stat.size, stat.mtime)
                    until event_log.eof?
                        pos = event_log.tell
                        yield(Float(pos) / end_pos) if block_given?

                        cycle = event_log.load_one_cycle
                        write_one_cycle(index_io, pos, cycle)
                    end
                rescue EOFError # rubocop:disable Lint/SuppressedException
                ensure
                    index_io&.flush
                end

                # Convert a log's cycle into the info hash expected in the index file
                #
                # @param [Integer] pos the position of the cycle in the log file
                # @param cycle the decoded cycle information, as returned by e.g.
                #   Reader#load_one_cycle
                def self.process_one_cycle(pos, cycle)
                    info = cycle.last.last
                    event_count = 0
                    cycle.each_slice(4) do |m, *|
                        event_count += 1 if m.to_s !~ /^timepoint/
                    end
                    info[:event_count] = event_count
                    info[:pos] = pos
                    info
                end

                # Write the index's header
                #
                # @param [Integer] size the size of the log file being indexed
                # @param [Time] mtime the modification time of the log file being indexed
                def self.write_header(index_io, size, mtime)
                    index_io.write(
                        [size, mtime.tv_sec, mtime.tv_nsec].pack("Q<L<L<")
                    )
                end

                # Write a cycle's index entry based on the decoded log chunk
                #
                # @param index_io the IO object to write to
                # @param [Integer] pos the position of the cycle's data
                # @param cycle the cycle data, decoded with e.g. Reader#load_one_cycle
                def self.write_one_cycle(index_io, pos, cycle)
                    info = process_one_cycle(pos, cycle)
                    write_entry(index_io, info)
                end

                # Write an index entry from the raw info hash
                #
                # @param index_io the IO object to write to
                # @param [Hash] info the info hash to be saved in the index
                def self.write_entry(index_io, info)
                    info = ::Marshal.dump(info)
                    Logfile.write_entry(index_io, info)
                end

                # Rebuild the index of a given log file
                #
                # @param [Pathname] log_path
                # @param [Pathname] index_path
                def self.rebuild_file(log_path, index_path)
                    File.open(log_path, "r") do |event_io|
                        File.open(index_path, "w") do |index_io|
                            Index.rebuild(event_io, index_io)
                        end
                    end
                end

                # The size in bytes of the file that has been indexed
                attr_reader :file_size
                # The modification time of the file that has been indexed
                attr_reader :file_time
                # The index data
                #
                # @return [Array<Hash>]
                attr_reader :data

                def initialize(file_size, file_time, data)
                    @file_size = file_size
                    @file_time = file_time
                    @data = data
                end

                def size
                    data.size
                end

                def [](*args)
                    data[*args]
                end

                def each(&block)
                    data.each(&block)
                end

                include Enumerable

                # Tests whether this index is valid for a given file
                #
                # @param [String] path the log file path
                # @return [Boolean]
                def valid_for?(path)
                    stat = File.stat(path)
                    stat.size == file_size && stat.mtime == file_time
                end

                # Returns the number of cycles in this index
                def cycle_count
                    data.size
                end

                # Tests whether this index contains cycles
                def empty?
                    data.empty?
                end

                # The time range
                #
                # @return [nil,(Time,Time)]
                def range
                    return if data.empty?

                    [Time.at(*data.first[:start]),
                     Time.at(*data.last[:start]) + data.last[:end]]
                end

                # Read an index file
                #
                # @param [String] filename the index file path
                def self.read(filename)
                    io = File.open(filename)
                    file_info = io.read(16)
                    size, tv_sec, tv_nsec = file_info.unpack("Q<L<L<")
                    data = []
                    begin
                        data << ::Marshal.load(Logfile.read_one_chunk(io)) until io.eof?
                    rescue EOFError # rubocop:disable Lint/SuppressedException
                    end

                    new(size, Time.at(tv_sec, Rational(tv_nsec, 1000)), data)
                ensure
                    io&.close
                end

                # Returns whether an index file exists and is valid for a log file
                #
                # @param [String] path the path to the log file
                # @param [String] index_path the path to the
                def self.valid_file?(path, index_path)
                    File.exist?(index_path) &&
                        read(index_path).valid_for?(path)
                end
            end
        end
    end
end
