require 'roby/support'

module Roby
    @event_processing = []
    class << self
        attr_reader :event_processing
    end

    def self.disable_propagation; EventGenerator.disable_propagation end
    def self.enable_propagation; EventGenerator.enable_propagation end
    def self.propagate?; EventGenerator.propagate? end

    def self.drb(drb_uri = nil)
        require 'roby/drb'
        DRb.start_service(drb_uri, Server.new(Thread.current))
        Roby.info "Started DRb server on #{drb_uri}"
    end

    def self.process_events
        # Current time
        cycle_start = Time.now

        # Get the events received by the server and process them
        cycle_server = Time.now
        Thread.current.process_events
        
        # Call event processing registered by other modules
        cycle_handlers = Time.now
        event_processing.each { |prc| prc.call }
        
        cycle_end = Time.now
        cycle_duration = cycle_end - cycle_start

        #Roby.debug { 
        #    "Object allocation profile:" <<
        #    ObjectStats.profile { GC.start }.collect do |klass, count|
        #        "  #{klass}: #{count}"
        #    end.join("\n")
        #}

        #Roby.debug { 
        #    [
	#	"start: #{cycle_start}, end: #{cycle_end}",
        #        cycle_server ? "  server events: #{cycle_handlers - cycle_server}" : nil,
        #        "  event handlers: #{cycle_end - cycle_handlers}",
	#	"Total: #{cycle_duration}s" 
        #    ].compact.join("\n")
        #}

        cycle_duration
    end

    # The main event loop
    def self.run(drb_uri = nil, cycle = 0.1)
        drb(drb_uri) if drb_uri
        cycle_start, cycle_server, cycle_handlers = nil
        GC.disable
        GC.start

        yield if block_given?
        loop do
            cycle_start = Time.now
            process_events

            GC.start
            cycle_duration = Time.now - cycle_start
            if cycle > cycle_duration
                sleep(cycle - cycle_duration)
            end
        end

    rescue Interrupt
        if drb_uri
            DRb.stop_service
        end
        puts "Quitting"

    ensure
	GC.enable
    end
end

