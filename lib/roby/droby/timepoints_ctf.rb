# frozen_string_literal: true

require "securerandom"

module Roby
    module DRoby
        module Timepoints
            class CTF
                attr_reader :uuid, :clock_base, :name_to_addr_mapping, :packet_timestamp_begin, :packet_timestamp_end, :packet_contents, :thread_ids

                def initialize(clock_base: 0)
                    @uuid = SecureRandom.random_bytes(16).unpack("C*")
                    @clock_base = clock_base

                    @packet_timestamp_begin = nil
                    @packet_timestamp_end = nil
                    @packet_contents = String.new
                    @name_to_addr_mapping = {}

                    @thread_ids = {}
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

                def thread_id_of(thread_id)
                    if id = thread_ids[thread_id]
                        id
                    else
                        thread_ids[thread_id] = thread_ids.size
                    end
                end

                def group_start(time, thread_id, thread_name, name)
                    marshalled = marshal_event(time, ID_GROUP_START, thread_id_of(thread_id), thread_name, name)
                    update_packet(time, marshalled + [addr_from_name(name)].pack("L<"))
                end

                def group_end(time, thread_id, thread_name, name)
                    update_packet(time, marshal_event(time, ID_GROUP_END, thread_id_of(thread_id), thread_name, name))
                end

                def add(time, thread_id, thread_name, name)
                    update_packet(time, marshal_event(time, ID_TIMEPOINT, thread_id_of(thread_id), thread_name, name))
                end

                def self.generate_metadata(path, uuid, _clock_base)
                    uuid_s = uuid.map { |v| format("%02x", v) }.join
                    uuid_s = "#{uuid_s[0, 8]}-#{uuid_s[8, 4]}-#{uuid_s[12, 4]}-"\
                             "#{uuid_s[16, 4]}-#{uuid_s[20, 12]}"
                    ERB.new(path.read).result(binding)
                end

                def metadata_template_path
                    Pathname.new(__FILE__).dirname + "timepoints_ctf.metadata.erb"
                end

                def generate_metadata
                    self.class.generate_metadata(metadata_template_path, uuid, clock_base)
                end

                def marshal_event(time, event_id, thread_id, thread_name, name)
                    timestamp = make_timestamp(time)
                    event_header =
                        [0xFFFF, event_id, make_timestamp(time)]
                        .pack("S<L<Q<")
                    thread_name ||= ""
                    event_context =
                        [thread_id, thread_name.size, thread_name, name.size, name]
                        .pack("L<S<A#{thread_name.size}S<A#{name.size}")
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
                        0
                    ].pack("Q<Q<L<")

                    @packet_timestamp_begin = nil
                    @packet_timestamp_end = nil
                    @packet_contents = String.new
                    header + context + contents
                end

                def save(path)
                    (path + "metadata").open("w") do |io|
                        io.write generate_metadata
                    end
                    (path + "channel0_0").open("w") do |io|
                        io.write marshal_packet
                    end
                    path.sub_ext(".ctf.names").open("w") do |io|
                        name_to_addr_mapping.each do |name, id|
                            io.puts(format("%016x T %s", id, name.gsub(/[^\w]/, "_")))
                        end
                    end
                end
            end
        end
    end
end
