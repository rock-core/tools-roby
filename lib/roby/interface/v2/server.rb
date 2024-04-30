# frozen_string_literal: true

module Roby
    module Interface
        module V2
            # The server-side object allowing to access an interface (e.g. a Roby app)
            # through any communication channel
            class Server
                # @return [Channel] the IO to the client
                attr_reader :io
                # @return [Interface] the interface object we are giving access to
                attr_reader :interface
                # @return [String] a string that allows the user to identify the client
                attr_reader :client_id

                # @return [Boolean] whether the messages should be
                #   forwarded to our clients
                attr_predicate :notifications_enabled?, true

                # @param [Channel] io a channel to the server
                # @param [Interface] interface the interface object we give remote
                #   access to
                def initialize(io, interface, main_thread: Thread.current)
                    @notifications_enabled = true
                    @io = io
                    @interface = interface
                    @main_thread = main_thread
                    @pending_packets = Queue.new
                    @performed_handshake = false
                end

                # Listen to notifications on the underlying interface
                def listen_to_notifications
                    listeners = []
                    listeners << @interface.on_cycle_end do
                        write_packet(
                            [
                                :cycle_end,
                                [@interface.execution_engine.cycle_index,
                                 @interface.execution_engine.cycle_start]
                            ], defer_exceptions: true
                        )
                    end
                    listeners << @interface.on_notification do |*args|
                        if notifications_enabled?
                            queue_packet([:notification, args])
                        elsif Thread.current == @main_thread
                            flush_pending_packets
                        end
                    end
                    listeners << @interface.on_ui_event do |*args|
                        queue_packet([:ui_event, args])
                    end
                    listeners << @interface.on_job_notification do |*args|
                        write_packet([:job_progress, args], defer_exceptions: true)
                    end
                    listeners << @interface.on_exception do |*args|
                        write_packet([:exception, args], defer_exceptions: true)
                    end
                    @listeners = Roby.disposable(*listeners)
                end

                # Write or queue a call, depending on whether the current thread is
                # the main thread
                #
                # Time ordering between out-of-thread and in-thread packets is not
                # guaranteed, so this can only be used in cases where it does not matter.
                def queue_packet(call)
                    if Thread.current == @main_thread
                        write_packet(call, defer_exceptions: true)
                    else
                        @pending_packets << call
                    end
                end

                # Flush packets queued from {#queue_packet}
                def flush_pending_packets
                    packets = []
                    until @pending_packets.empty?
                        packets << @pending_packets.pop
                    end
                    packets.each do |p|
                        write_packet(p, defer_exceptions: true)
                    end
                end

                def to_io
                    io.to_io
                end

                def handshake(id, commands)
                    @client_id = id
                    Roby::Interface.info "new interface client: #{id}"
                    result = commands.each_with_object({}) do |s, result|
                        result[s] = interface.send(s)
                    end
                    @performed_handshake = true
                    listen_to_notifications
                    result
                end

                # Whether the remote side already called {#handshake}
                def performed_handshake?
                    @performed_handshake
                end

                def enable_notifications
                    self.notifications_enabled = true
                end

                def disable_notifications
                    self.notifications_enabled = false
                end

                def closed?
                    io.closed?
                end

                def close
                    io.close
                    @listeners&.dispose
                end

                def process_batch(path, calls)
                    calls.map do |p, m, a, kw|
                        process_call(path + p, m, a, kw)
                    end
                end

                def process_call(path, name, args, keywords)
                    if path.empty? && respond_to?(name)
                        send(name, *args, **keywords)
                    else
                        process_interface_call(path, name, args, keywords)
                    end
                end

                def process_interface_call(path, name, args, keywords)
                    receiver = path.inject(interface) do |obj, subcommand|
                        obj.send(subcommand)
                    end
                    receiver.send(name, *args, **keywords)
                end

                def has_deferred_exception?
                    @deferred_exception
                end

                def write_packet(call, defer_exceptions: false)
                    return if has_deferred_exception?

                    flush_pending_packets
                    io.write_packet(call)
                rescue Exception => e
                    if defer_exceptions
                        @deferred_exception = e
                    else
                        raise
                    end
                end

                # Process one command from the client, and send the reply
                def poll
                    raise @deferred_exception if has_deferred_exception?

                    path, m, args, keywords = io.read_packet
                    return unless m

                    begin
                        reply =
                            if m == :process_batch
                                process_batch(path, args.first)
                            else
                                process_call(path, m, args, keywords)
                            end

                        true
                    rescue Exception => e
                        write_packet([:bad_call, e])
                        return
                    end

                    begin
                        write_packet([:reply, reply])
                    rescue ComError
                        raise
                    rescue Exception => e
                        write_packet([:protocol_error, e])
                        raise
                    end
                end
            end
        end
    end
end
