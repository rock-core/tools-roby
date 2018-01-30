module Roby
    module DRoby
        module Logfile
            class Index
                # Creates an index file for +event_log+ in +index_log+
                def self.rebuild(event_io, index_io)
                    stat = File.stat(event_io.path)
                    event_log = Reader.new(event_io)

                    index_io.write [stat.size, stat.mtime.tv_sec, stat.mtime.tv_nsec].pack("Q<L<L<")
                    dump_io     = StringIO.new("", 'w')
                    while !event_log.eof?
                        current_pos = event_log.tell
                        cycle = event_log.load_one_cycle
                        info  = cycle.last.last
                        event_count = 0
                        cycle.each_slice(4) do |m, *|
                            if m.to_s !~ /^timepoint/
                                event_count += 1
                            end
                        end
                        info[:event_count] = event_count
                        info[:pos] = current_pos

                        if block_given?
                            yield(Float(event_io.tell) / end_pos)
                        end

                        info = ::Marshal.dump(info)
                        index_io.write [info.size].pack("L<")
                        index_io.write info
                    end

                rescue EOFError
                ensure index_io.flush if index_io
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
                    if !data.empty?
                        [Time.at(*data.first[:start]), 
                         Time.at(*data.last[:start]) + data.last[:end]]
                    end
                end

                # Read an index file
                #
                # @param [String] filename the index file path
                def self.read(filename)
                    io = File.open(filename)
                    file_info = io.read(16)
                    size, tv_sec, tv_nsec = file_info.unpack("Q<L<L<")
                    data = Array.new
                    begin
                        while !io.eof?
                            data << ::Marshal.load(Logfile.read_one_chunk(io))
                        end
                    rescue EOFError
                    end

                    new(size, Time.at(tv_sec, Rational(tv_nsec, 1000)), data)
                end
            end
        end
    end
end

