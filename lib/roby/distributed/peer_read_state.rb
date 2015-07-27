module Roby
    module Distributed
        class PeerReadState
            attr_reader :completed_calls

            attr_reader :peer

            attr_reader :raw_header
            attr_reader :id
            attr_reader :size

            attr_reader :raw_payload

            def initialize(peer)
                @completed_calls = 0
                @peer = peer
                @raw_header = String.new
                @raw_payload = String.new
                reset
            end

            def reset
                @id = nil
                @raw_header.clear
                @raw_payload.clear
            end

            HEADER_SIZE = 8

            def to_s
                "#<PeerReadState: #{peer} #{completed_calls} header.size=#{raw_header.size} payload.size=#{raw_payload.size}>"
            end

            def read_nonblock(socket)
                if !id
                    while raw_header.size < HEADER_SIZE
                        data = socket.read_nonblock(HEADER_SIZE - raw_header.size)
                        peer.stats.rx += data.size
                        raw_header.concat(data)
                    end
                    @id, @size = raw_header.unpack("NN")
                end

                while raw_payload.size < size
                    data = socket.read_nonblock(size - raw_payload.size)
                    peer.stats.rx += data.size
                    raw_payload.concat(data)
                end

                @completed_calls += 1
                Marshal.load(raw_payload)
            end
        end
    end
end
