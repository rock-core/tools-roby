module Roby
    module DRoby
        # Module containing all the logfile-related code
        #
        # Note that unlike other Roby facilities, this file is not meant to be
        # required directly. Require either logfile/reader or logfile/writer
        # depending on what you need
        module Logfile
            extend Logger::Hierarchy

            MAGIC_CODE = "ROBYLOG"
            PROLOGUE_SIZE = MAGIC_CODE.size + 4
            FORMAT_VERSION = 5

            class IndexInvalid < RuntimeError; end
            class IndexMissing < RuntimeError; end

            # Exception raised when attempting to guess the format version of a
            # log file, and the guess fails
            class UnknownFormatVersion < RuntimeError; end

            # Execption raised when loading a good-looking prologue of a log
            # file, but the contained log version does not match our
            # expectations
            class InvalidFormatVersion < RuntimeError; end

            # Exception raised when attempting to load a file that does not look
            # like a Roby log file
            class InvalidFileError < RuntimeError; end

            class TruncatedFileError < InvalidFileError; end

            def self.write_prologue(io)
                io.write(MAGIC_CODE)
                io.write([FORMAT_VERSION].pack("L<"))
            end

            # Write a log file header
            #
            # The created log file will always have {FORMAT_VERSION} as its
            # version field
            def self.write_header(io, options = Hash.new)
                write_prologue(io)
                options = ::Marshal.dump(options)
                io.write [options.size].pack("L<")
                io.write options
            end

            # Guess the log file format version for the given IO
            def self.guess_version(input)
                input.rewind

                magic = input.read(Logfile::MAGIC_CODE.size)
                if magic == Logfile::MAGIC_CODE
                    return input.read(4).unpack("L<").first
                else
                    input.rewind
                    header =
                        begin ::Marshal.load(input)
                        rescue TypeError
                            return
                        end

                    case header
                    when Hash then return header[:log_format]
                    when Symbol
                        first_chunk =
                            begin ::Marshal.load(input)
                            rescue TypeError
                                return
                            end

                        if first_chunk.kind_of?(Array)
                            return 0
                        end
                    when Array
                        if header[-2] == :cycle_end
                            return 1 
                        end
                    end
                end

            ensure
                input.rewind
            end

            # Read a file prologue, validating that it is of the latest file
            # format
            #
            # @raise [InvalidFileError,InvalidFormatVersion,UnknownFormatVersion]
            def self.read_prologue(io)
                magic = io.read(MAGIC_CODE.size)
                if magic != MAGIC_CODE
                    raise InvalidFileError, "no magic code at beginning of file"
                end

                log_format = io.read(4).unpack('I').first
                validate_format(log_format)

            rescue InvalidFormatVersion
                raise
            rescue Exception => e
                if format = guess_version(io)
                    validate_format(format)
                else
                    raise
                end
            end

            # @api private
            #
            # Validate the given format version
            #
            # @raise [InvalidFormatVersion]
            def self.validate_format(format)
                if format < FORMAT_VERSION
                    raise InvalidFormatVersion, "this is an outdated format (#{format}, current is #{FORMAT_VERSION}). Please run roby-log upgrade-format"
                elsif format > FORMAT_VERSION
                    raise InvalidFormatVersion, "this is an unknown format version #{format}: expected #{FORMAT_VERSION}. This file can be read only by newest version of Roby"
                end
            end

            # Load a chunk of data from an event file. +buffer+, if given, must be
            # a String object that will be used as intermediate buffer in the
            # process
            def self.read_one_chunk(io)
                data_size = io.read(4)
                if !data_size
                    raise EOFError, "expected a chunk at position #{io.tell}, but got EOF"
                end

                data_size = data_size.unpack("L<").first
                buffer = io.read(data_size)
                if !buffer || buffer.size < data_size
                    raise TruncatedFileError, "expected a chunk of size #{data_size} at #{io.tell}, but got only #{buffer ? buffer.size : '0'} bytes"
                end

                buffer
            end
        end
    end
end

