module Roby
    module Distributed
        # Handling of connection requests in dRoby
        #
        # This is singled-out as it is a very concurrent process (our peers
        # might try to connect to us at the same time than we are connecting to
        # them), which makes a lot of clutter and complexity.
        class ConnectionRequest
            # ConnectionToken objects are used to sort out concurrent
            # connections, i.e. cases where two peers are trying to initiate a
            # connection with each other at the same time.
            #
            # When this situation appears, each peer compares its own token
            # with the one sent by the remote peer. The greatest token wins and
            # is considered the initiator of the connection.
            #
            # See #initiate_connection
            class ConnectionToken
                attr_reader :time, :value
                def initialize
                    @time  = Time.now
                    @value = rand
                end
                def <=>(other)
                    result = (time <=> other.time)
                    if result == 0
                        value <=> other.value
                    else
                        result
                    end
                end
                include Comparable
            end

            # The thread that is trying to connect to the remote peer
            #
            # @return [Thread,nil] the thread object, or nil if {#initiate} has
            #   not yet been called
            attr_reader :connection_thread

            # A list of callbacks that should be called with the remote peer's
            # reply
            #
            # @return # [Array<#call(ConnectionRequest,socket,remote_uri,remote_port,remote_state)>]
            #   information about the remote peer's reply. See {Peer}
            #   documentation for more information
            attr_reader :callbacks

            # The peer we are connecting/reconnecting to
            #
            # @return [Peer]
            attr_reader :peer

            # The token that allows to discriminate between concurrent
            # connections
            #
            # @return [ConnectionToken]
            attr_reader :token

            def self.connect(peer, &block)
                request = new(peer, reconnecting: false, callback: block)
                request.initiate
            end

            def self.reconnect(peer, &block)
                request = new(peer, reconnecting: true, callback: block)
                request.initiate
            end

            def initialize(peer, reconnecting: false, callback: nil)
                @callbacks = Array.new
                if callback
                    callbacks << callback
                end
                @reconnecting = reconnecting
                @peer   = peer
                @token = ConnectionToken.new
            end

            def connection_space
                peer.connection_space
            end

            def reconnecting?
                !!@reconnecting
            end

            # Initiate a connection
            #
            # @return [Thread] the thread that is handling the connection itself
            def initiate
                return if !peer.register_connection_request(self)

                m = if reconnecting? then :reconnect
                    else :connect
                    end

                call = [m, token, connection_space.name, connection_space.remote_id, Distributed.format(Roby::State)]
                @connection_thread = Thread.new do
                    send_thread_main(call)
                end
            end

            # @api private
            #
            # Handling of connection. It is called in a separate thread by
            # {#inititiate}, and will either queue {#callbacks}, on completion,
            # or call {Peer#aborted_connection_request} on error. These calls
            # will be queued in the underlying execution engine (as returned by
            # {Peer#execution_engine}.
            def send_thread_main(call)
                Thread.current.abort_on_exception = false

                remote_id = peer.remote_id
                socket = TCPSocket.new(remote_id.uri, remote_id.ref)

                socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
                Distributed.debug "#{call[0]}: #{peer} on #{socket.peer_info}"

                # Send the connection request
                call = Marshal.dump(call)
                socket.write [call.size].pack("N")
                socket.write call

                reply_size = socket.read(4)
                if !reply_size
                    raise Errno::ECONNRESET, "connection reset"
                end
                reply = Marshal.load(socket.read(*reply_size.unpack("N")))

                peer.once do
                    reply, *info = *reply
                    if reply == :connected || reply == :reconnected
                        callbacks.each do |callback|
                            callback.call(self, socket, *reply)
                        end
                    else
                        socket.close
                        peer.aborted_connection_request(self)
                    end
                end

            rescue Exception => e
                socket.close if !socket.closed?
                peer.once do
                    peer.aborted_connection_request(self, reason: e)
                end
            end
        end
    end
end
