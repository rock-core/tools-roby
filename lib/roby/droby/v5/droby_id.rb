module Roby
    module DRoby
        module V5
            # These objects are used in distributed Roby to identify objects across
            # the various Roby instances
            class DRobyID
                # The object ID
                attr_reader :id

                def initialize(id)
                    @id = id
                    @marshal_id = [id].pack("Q<")
                    @hash = id.hash
                end

                def ==(other) # :nodoc:
                    other.kind_of?(DRobyID) && other.id == id
                end

                alias :eql? :==
                attr_reader :hash

                def to_s
                    "#<DRobyID:#{id}>"
                end
                def inspect
                    to_s
                end
                def pretty_print(pp)
                    pp.text to_s
                end

                def marshal_dump
                    @marshal_id
                end

                def marshal_load(packed)
                    @id = packed.unpack("Q<").first
                    @hash = id.hash
                end

                def self.droby_id_allocator
                    @@droby_id_allocator
                end

                # Reserve the first 100 IDs for special use
                LOCAL_PEER_ID = 0
                EVENT_LOG_ID  = 1

                @@droby_id_allocator = Concurrent::AtomicFixnum.new(1000)

                def self.allocate
                    DRobyID.new(@@droby_id_allocator.increment)
                end
            end
        end
    end
end

