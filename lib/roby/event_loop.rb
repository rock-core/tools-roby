require 'roby/base'

module Roby
    @event_processing = []
    class << self
        attr_reader :event_processing
    end

    # The main event loop
    def self.run(drb_uri = nil, cycle = 0.1)
        # Start the DRb server if needed
        if drb_uri
            require 'roby/drb'
            DRb.start_service(drb_uri, Server.new(Thread.current))
            Roby.info "Started DRb server on #{drb_uri}"
        end

        cycle_start, cycle_server, cycle_handlers = nil
        
        yield if block_given?
        loop do
            # Current time
            cycle_start = Time.now
            Roby.debug { "Starting cycle at #{cycle_start}" }

            # Get the events received by the server and process them
            if drb_uri
                Roby.debug {
                    cycle_server = Time.now
                    "Processing server commands"
                }
                Thread.current.process_events
                Roby.debug { "Server events processed in #{Time.now - cycle_server}" }
            end
            
            # Call event processing registered by other modules
            Roby.debug {
                cycle_handlers = Time.now
                "Processing server commands"
            }
            event_processing.each { |prc| prc.call }
            Roby.debug { "Event handlers processed in #{Time.now - cycle_handlers}" }
            
            cycle_end = Time.now
            cycle_duration = cycle_end - cycle_start
            Roby.debug { "Event processing took #{cycle_duration}" }

            sleep(cycle - cycle_duration)
        end

    rescue Interrupt
        if drb_uri
            DRb.stop_service
        end
        puts "Quitting"
    end
end

