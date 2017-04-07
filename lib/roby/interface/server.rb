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
            # Controls whether non-communication-related errors should cause the
            # whole Roby engine to terminate
            #
            # This is true by default, as for most systems the Roby interface is
            # the only mean of communication. Turn this off only if you have
            # other ways to control your system, or if having it running without
            # human control is safer than shutting it down.
            attr_predicate :abort_on_exception?, true
            # @return [Boolean] whether the messages should be
            #   forwarded to our clients
            attr_predicate :notifications_enabled?, true

            # @param [DRobyChannel] io a channel to the server
            # @param [Interface] interface the interface object we give remote
            #   access to
            def initialize(io, interface)
                @notifications_enabled = true
                @abort_on_exception = true
                @io, @interface = io, interface

                interface.on_cycle_end do
                    write_packet([
                        :cycle_end,
                        interface.execution_engine.cycle_index,
                        interface.execution_engine.cycle_start],
                        defer_exceptions: true)
                end
                interface.on_notification do |*args|
                    if notifications_enabled?
                        write_packet([:notification, *args], defer_exceptions: true)
                    end
                end
                interface.on_job_notification do |*args|
                    write_packet([:job_progress, *args], defer_exceptions: true)
                end
                interface.on_exception do |*args|
                    write_packet([:exception, *args], defer_exceptions: true)
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

            def has_deferred_exception?
                !!@deferred_exception
            end

            def write_packet(call, defer_exceptions: false)
                return if has_deferred_exception?

                io.write_packet(call)
            rescue Exception => e
                if defer_exceptions
                    @deferred_exception = e
                else raise
                end
            end

            # Process one command from the client, and send the reply
            def poll
                if has_deferred_exception?
                    raise @deferred_exception
                end

                path, m, *args = io.read_packet
                return if !m

                if m == :process_batch
                    begin
                        reply = Array.new
                        args.first.each do |p, m, *a|
                            reply << process_call(path + p, m, *a)
                        end
                    rescue Exception => e
                        write_packet([:bad_call, e])
                        return
                    end
                    write_packet([:reply, reply])
                else
                    begin
                        reply = process_call(path, m, *args)
                    rescue Exception => e
                        write_packet([:bad_call, e])
                        return
                    end
                    write_packet([:reply, reply])
                end

            rescue ComError
                raise
            rescue Exception => e
                if abort_on_exception?
                    raise
                else raise ComError, "error while doing I/O processing: #{e.message}"
                end
            end
        end
    end
end

