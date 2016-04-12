require 'securerandom'

module Roby
    module DRoby
        module Timepoints
            class CTF
                attr_reader :uuid
                attr_reader :clock_base
                attr_reader :name_to_addr_mapping

                attr_reader :packet_timestamp_begin
                attr_reader :packet_timestamp_end
                attr_reader :packet_contents

                def initialize(clock_base: 0)
                    @uuid = SecureRandom.random_bytes(16).unpack("C*")
                    @clock_base = clock_base

                    @packet_timestamp_begin = nil
                    @packet_timestamp_end = nil
                    @packet_contents = String.new
                    @name_to_addr_mapping = Hash.new
                end

                def make_timestamp(time)
                    (time.tv_sec - clock_base) * 1_000_000 + time.tv_usec
                end

                def addr_from_name(name)
                    name_to_addr_mapping[name] ||= name_to_addr_mapping.size
                end

                ID_TIMEPOINT = 1
                ID_GROUP_START = 2
                ID_GROUP_END = 3

                def update_packet(time, marshalled_event)
                    @packet_timestamp_begin ||= time
                    @packet_timestamp_end = time
                    packet_contents << marshalled_event
                end

                def group_start(time, name)
                    marshalled = marshal_event(time, ID_GROUP_START, 0, name)
                    update_packet(time, marshalled + [addr_from_name(name)].pack("L<"))
                end

                def group_end(time, name)
                    update_packet(time, marshal_event(time, ID_GROUP_END, 0, name))
                end

                def add(time, name)
                    update_packet(time, marshal_event(time, ID_TIMEPOINT, 0, name))
                end

                def self.generate_metadata(path, _uuid, _clock_base)
                    _uuid_s = _uuid.map { |v| "%02x" % v }.join
                    _uuid_s = "#{_uuid_s[0, 8]}-#{_uuid_s[8, 4]}-#{_uuid_s[12, 4]}-#{_uuid_s[16, 4]}-#{_uuid_s[20, 12]}"
                    ERB.new(path.read).result(binding)
                end

                def metadata_template_path
                    Pathname.new(__FILE__).dirname + "timepoints_ctf.metadata.erb"
                end

                def generate_metadata
                    self.class.generate_metadata(metadata_template_path, uuid, clock_base)
                end

                def marshal_event(time, event_id, thread_id, name)
                    timestamp = make_timestamp(time)
                    event_header  = [0xFFFF, event_id, make_timestamp(time)].pack("S<L<Q<")
                    event_context = [thread_id, 0, name.size, name].pack("L<S<S<A#{name.size}")
                    event_header + event_context
                end

                def marshal_packet
                    header = [
                        0xC1FC1FC1, # Magic
                        *uuid,
                        0 # Stream ID
                    ].pack("L<C16L<")
                    contents = packet_contents
                    context = [
                        make_timestamp(packet_timestamp_begin),
                        make_timestamp(packet_timestamp_end),
                        0].pack("Q<Q<L<")

                    @packet_timestamp_begin = nil
                    @packet_timestamp_end = nil
                    @packet_contents = String.new
                    header + context + contents
                end

                def save(path)
                    (path + "metadata").open('w') do |io|
                        io.write generate_metadata
                    end
                    (path + "channel0_0").open('w') do |io|
                        io.write marshal_packet
                    end
                    (path + "name_mappings.txt").open('w') do |io|
                        name_to_addr_mapping.each do |name, id|
                            io.puts("%016x T %s" % [id, name.gsub(/[^\w]/, '_')])
                        end
                    end
                end
            end
        end
    end
end

