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
            # @return [Boolean] whether the messages should be
            #   forwarded to our clients
            attr_predicate :notifications_enabled?, true

            # @param [DRobyChannel] io a channel to the server
            # @param [Interface] interface the interface object we give remote
            #   access to
            def initialize(io, interface)
                @notifications_enabled = true
                @io, @interface = io, interface

                interface.on_cycle_end do
                    begin
                        io.write_packet([:cycle_end, interface.execution_engine.cycle_index, interface.execution_engine.cycle_start])
                    rescue ComError
                        # The disconnection is going to be handled by the caller
                        # of #poll
                    end
                end
                interface.on_notification do |*args|
                    if notifications_enabled?
                        begin
                            io.write_packet([:notification, *args])
                        rescue ComError
                            # The disconnection is going to be handled by the caller
                            # of #poll
                        end
                    end
                end
                interface.on_job_notification do |*args|
                    begin
                        io.write_packet([:job_progress, *args])
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
                Roby::Interface.info "new interface client: #{id}"
                return interface.actions, interface.commands
            end

            def enable_notifications
                self.notifications_enabled = false
            end

            def disable_notifications
                self.notifications_enabled = false
            end

            def closed?
                io.closed?
            end

            def close
                io.close
            end

            def process_call(path, m, *args)
                if path.empty? && respond_to?(m)
                    send(m, *args)
                else
                    receiver = path.inject(interface) do |obj, subcommand|
                        obj.send(subcommand)
                    end
                    receiver.send(m, *args)
                end
            end

            # Process one command from the client, and send the reply
            def poll
                path, m, *args = io.read_packet
                return if !m

                if m == :process_batch
                    reply = Array.new
                    args.first.each do |p, m, *a|
                        reply << process_call(path + p, m, *a)
                    end
                else
                    reply = process_call(path, m, *args)
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

