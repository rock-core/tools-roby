# frozen_string_literal: true

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
                    @peer_id = peer_id
                    @droby_id = droby_id

                    @hash = [@peer_id, @droby_id].hash
                end

                def eql?(other)
                    other.kind_of?(RemoteDRobyID) &&
                        other.peer_id == peer_id &&
                        other.droby_id == droby_id
                end

                def ==(other)
                    eql?(other)
                end

                def to_s
                    "#<RemoteDRobyID #{peer_id}@#{droby_id}>"
                end
            end
        end
    end
end
