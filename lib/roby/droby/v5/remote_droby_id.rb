module Roby
    module DRoby
        module V5
            # Cross-instance identification of an object
            class RemoteDRobyID
                # The peer on which the object is known as {#droby_id}
                #
                # @return [PeerID]
                attr_reader :peer_id

                # The object ID
                #
                # @return [DRobyID]
                attr_reader :droby_id

                # The ID hash value
                #
                # The values are immutable, so the hash value is computed once
                # and cached here
                attr_reader :hash

                def initialize(peer_id, droby_id)
                    @peer_id  = peer_id
                    @droby_id = droby_id

                    @ids = [@peer_id.id, @droby_id.id].pack("Q<Q<")
                    @hash = @ids.hash
                end

                def marshal_dump
                    @ids
                end

                def marshal_load(ids)
                    peer_id, droby_id = ids.unpack("Q<Q<")
                    @peer_id  = PeerID.new(peer_id)
                    @droby_id = DRobyID.new(droby_id)
                    @ids = [@peer_id.id, @droby_id.id].pack("Q<Q<")
                    @hash = @ids.hash
                end

                def eql?(obj)
                    obj.kind_of?(RemoteDRobyID) &&
                        obj.peer_id == peer_id && obj.droby_id == droby_id
                end
                def ==(obj); eql?(obj) end

                def to_s
                    "#<RemoteDRobyID #{droby_id}@#{peer_id}>"
                end
            end
        end
    end
end

