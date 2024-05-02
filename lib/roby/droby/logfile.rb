# frozen_string_literal: true

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

            # Write the file's prologue, specifying the file magic and format version
            #
            # The version ID can be specified here mostly for testing purposes.
            def self.write_prologue(io, version: FORMAT_VERSION)
                io.write(MAGIC_CODE)
                io.write([version].pack("L<"))
            end

            # Write a log file header
            #
            # The created log file will always have {FORMAT_VERSION} as its
            # version field
            def self.write_header(io, version: FORMAT_VERSION, **options)
                write_prologue(io, version: version)
                options = ::Marshal.dump(options)
                io.write [options.size].pack("L<")
                io.write options
            end

            # Guess the log file format version for the given IO
            def self.guess_version(input)
                input.rewind
                return unless (magic = input.read(Logfile::MAGIC_CODE.size))
                return input.read(4)&.unpack1("L<") if magic == Logfile::MAGIC_CODE

                guess_version_from_marshalled_header(input)
            ensure
                input.rewind
            end

            # @api private
            #
            # Guess the version of older files that had a single marshalled
            # object as header
            def self.guess_version_from_marshalled_header(input)
                input.rewind
                begin
                    header = ::Marshal.load(input) # rubocop:disable Security/MarshalLoad
                rescue TypeError
                    return
                end

                case header
                when Hash
                    header[:log_format]
                when Symbol
                    begin
                        first_chunk = ::Marshal.load(input) # rubocop:disable Security/MarshalLoad
                    rescue TypeError
                        return
                    end

                    0 if first_chunk.kind_of?(Array)
                when Array
                    1 if header[-2] == :cycle_end
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

                unless (log_format = io.read(4)&.unpack1("L<"))
                    raise InvalidFileError, "file truncated, cannot read prologue"
                end

                validate_format(log_format)
            rescue InvalidFormatVersion
                raise
            rescue StandardError
                raise unless (format = guess_version(io))

                validate_format(format)
            end

            # @api private
            #
            # Validate the given format version
            #
            # @raise [InvalidFormatVersion]
            def self.validate_format(format)
                if format < FORMAT_VERSION
                    raise InvalidFormatVersion,
                          "this is an outdated format (#{format}, current is " \
                          "#{FORMAT_VERSION}). Please run roby-log upgrade-format"
                elsif format > FORMAT_VERSION
                    raise InvalidFormatVersion,
                          "this is an unknown format version #{format}: " \
                          "expected #{FORMAT_VERSION}. This file can be read " \
                          "only by newer versions of Roby"
                end
            end

            # Load a chunk of data from an event file. +buffer+, if given, must be
            # a String object that will be used as intermediate buffer in the
            # process
            def self.read_one_chunk(io)
                data_size = io.read(4)
                return unless data_size

                actual_pos = io.tell
                unless (data_size = data_size.unpack1("L<"))
                    raise TruncatedFileError,
                          "file truncated, expected 4 bytes at #{actual_pos}"
                end

                buffer = io.read(data_size) || ""
                if buffer.size < data_size
                    raise TruncatedFileError,
                          "truncated file, expected a chunk of size #{data_size} " \
                          "at #{actual_pos + 4}, but got only " \
                          "#{buffer ? buffer.size : '0'} bytes"
                end

                buffer
            end

            # Decode a chunk loaded with {.read_one_chunk}
            def self.decode_one_chunk(chunk)
                begin ::Marshal.load_with_missing_constants(chunk)
                rescue ArgumentError => e
                    if e.message == "marshal data too short"
                        raise TruncatedFileError, "marshal data invalid"
                    end

                    raise
                end
            rescue TypeError => e
                case e.message
                when /^struct Roby::Actions::Models::Action::Argument not compatible/
                    Roby::Actions::Models::Action.const_set(
                        :Argument,
                        Struct.new(:name, :doc, :required, :default)
                    )
                    retry
                else
                    raise e, "#{e.message}, running roby-log repair " \
                             "might repair the file", e.backtrace
                end
            rescue Exception => e # rubocop:disable Lint/RescueException
                raise e, "#{e.message}, running roby-log repair " \
                         "might repair the file", e.backtrace
            end

            # Write a single entry in the log file
            def self.write_entry(io, chunk)
                io.write([chunk.size].pack("L<"))
                io.write chunk
            end
        end
    end
end
