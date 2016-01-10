require 'roby/droby/logfile'

module Roby
    module DRoby
        module Logfile
            # A class that marshals DRoby cycle events into a log file using
            # Ruby's Marshal facility
            class Writer
                # The current log format version
                FORMAT_VERSION = 5

                attr_reader :event_io
                attr_reader :buffer_io

                def initialize(event_io, options = Hash.new)
                    @event_io = event_io
                    @buffer_io = StringIO.new('', 'w')

                    Logfile.write_header(event_io, options)
                end

                def self.open(path, options = Hash.new)
                    event_io = File.open(path, 'w')
                    new(event_io, options)
                end

                def close
                    event_io.close
                end

                def dump_object(object, io)
                    buffer_io.truncate(0)
                    buffer_io.seek(0)
                    ::Marshal.dump(object, buffer_io)
                    io.write([buffer_io.size].pack("L<"))
                    io.write(buffer_io.string)
                end

                def flush
                    event_io.flush
                end

                def dump(cycle)
                    dump_object(cycle, event_io)

                rescue
                    self.class.find_invalid_marshalling_object_in_cycle(cycle)
                    raise
                end

                def self.find_invalid_marshalling_object_in_cycle(cycle)
                    cycle.each_slice(4) do |m, sec, usec, args|
                        begin
                            ::Marshal.dump(args)
                        rescue Exception => e
                            Roby::DRoby::Logfile.fatal "failed to dump cycle info: #{e}"
                            args.each do |obj|
                                begin
                                    ::Marshal.dump(obj)
                                rescue Exception => e
                                    Roby::DRoby::Logfile.fatal "cannot dump #{obj}"
                                    Roby::DRoby::Logfile.fatal e.to_s
                                    obj, exception = find_invalid_marshalling_object(obj)
                                    if obj
                                        Roby::DRoby::Logfile.fatal "  it seems that #{obj} can't be marshalled"
                                        Roby::DRoby::Logfile.fatal "    #{exception.class}: #{exception.message}"
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
                        ::Marshal.dump(obj)
                        nil
                    rescue Exception => e
                        begin
                            return "#{obj} (#{obj.class})", e
                        rescue Exception
                            return "-- cannot display object, #to_s raised -- (#{obj.class})", e
                        end
                    end
                end
            end
        end
    end
end

