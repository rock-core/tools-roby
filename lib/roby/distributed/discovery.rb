require 'concurrent'

module Roby
    module Distributed
        class Discovery
            attr_reader :listeners
            attr_reader :work
            attr_reader :thread_pool

            class Work
                attr_reader :future
                attr_reader :discovery
                attr_accessor :last_known_neighbours

                def initialize(discovery)
                    @future = nil
                    @discovery = discovery
                    @last_known_neighbours = Array.new
                end

                def can_respawn?
                    !future || future.completed?
                end

                def spawn(thread_pool)
                    @future = Concurrent::Future.new(executor: thread_pool) { discovery.neighbours }
                    future.execute
                end
                
                def neighbours
                    if future && future.completed?
                        if future.reason
                            Distributed.warn "Failed discovery on #{discovery}:"
                            Roby.log_exception_with_backtrace(future.reason, Distributed, :warn)
                            @last_known_neighbours = Array.new
                        elsif !future.value.respond_to?(:to_ary)
                            Distributed.warn "Failed discovery on #{discovery}: #neighbours did not return an array"
                            @last_known_neighbours = Array.new
                        else
                            @last_known_neighbours = future.value
                        end
                    else
                        last_known_neighbours
                    end
                end

                def wait
                    if future
                        future.value
                    end
                    neighbours
                end
            end

            def initialize
                @thread_pool = Concurrent::CachedThreadPool.new
                @work = Array.new
                @listeners = Hash.new
            end

            def start
                @work.each do |work|
                    if work.can_respawn?
                        work.spawn(thread_pool)
                    end
                end
            end

            def wait
                @work.flat_map do |w|
                    w.wait
                end
            end

            def add(discovery)
                w = Work.new(discovery)
                @work << w
                w
            end

            def delete(discovery)
                @work.delete_if do |w|
                    w.discovery == discovery
                end
                listeners.delete_if { |_, d| d == discovery }
            end

            def each_discovery_method
                return enum_for(__method__) if !block_given?
                @work.each do |w|
                    yield(w.discovery)
                end
            end

            # Returns the currently-known state of our neighbours
            #
            # Unlike {#wait}, this is non-blocking
            def neighbours
                work.flat_map do |d|
                    d.neighbours
                end.uniq
            end

            def quit
                listeners.values.dup.each do |d|
                    delete(d)
                end
            end

            def listen_to_tuplespace(tuplespace)
                if !tuplespace.respond_to?(:__drburi)
                    if tuplespace.respond_to?(:to_str)
                        tuplespace = DRbObject.new_with_uri("druby://#{tuplespace}")
                        key = tuplespace.__drburi
                    else
                        key = "local_tuplespace:#{tuplespace.object_id}"
                    end

                end
                if listeners[key]
                    raise ArgumentError, "already listening on tuplespace at #{key}"
                end
                listener = (listeners[key] = CentralDiscovery.new(tuplespace))
                listener.listen
                add(listener)
                listener
            end

            def listen_to_ring(broadcast_address, port: DEFAULT_RING_PORT, timeout: 2)
                if listeners[[broadcast_address, port]]
                    raise ArgumentError, "already listening on #{broadcast_address}:#{port}"
                end
                listener = (listeners[port] = RingDiscovery.new(port: port, timeout: timeout))
                listener.listen(broadcast_address)
                add(listener)
                listener
            end
        end
    end
end

