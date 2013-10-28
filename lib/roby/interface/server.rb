module Roby
    module Interface
        # The server-side object allowing to access an interface (e.g. a Roby app)
        # through any communication channel
        class Server
            # @return [DRobyChannel] the IO to the client
            attr_reader :io
            # @return [Interface] the interface object we are giving access to
            attr_reader :interface
            # @return [String] a string that allows the user to identify the client
            attr_reader :client_id

            # @param [DRobyChannel] io a channel to the server
            # @param [Interface] interface the interface object we give remote
            #   access to
            def initialize(io, interface)
                @io, @interface = io, interface
                interface.on_job_notification do |*args|
                    begin
                        io.write_packet([:notification, *args])
                    rescue ComError
                        # The disconnection is going to be handled by the caller
                        # of #poll
                    end
                end
                interface.on_exception do |*args|
                    begin
                        io.write_packet([:exception, *args])
                    rescue ComError
                        # The disconnection is going to be handled by the caller
                        # of #poll
                    end
                end
            end

            def to_io
                io.to_io
            end

            def handshake(id)
                @client_id = id
                Roby::Interface.warn "new interface client: #{id}"
                return interface.actions, interface.commands
            end

            def close
                io.close
            end

            # Process one command from the client, and send the reply
            def poll
                path, m, *args = io.read_packet
                return if !m

                if path.empty? && respond_to?(m)
                    reply = send(m, *args)
                else
                    receiver = interface
                    receiver = path.inject(interface) do |receiver, subcommand|
                        receiver.send(subcommand)
                    end
                    reply = receiver.send(m, *args)
                end

                io.write_packet([:reply, reply])
            rescue ComError
                raise
            rescue Exception => e
                io.write_packet([:bad_call, e])
            end
        end
    end
end

