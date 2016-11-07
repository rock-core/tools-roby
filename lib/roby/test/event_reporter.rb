module Roby
    module Test
        # A event-logging compatible object that is used to 
        class EventReporter
            # Whether the reporter should report anything
            attr_predicate :enabled?, true

            attr_reader :received_events

            def initialize(io, enabled: false)
                @io = io
                @enabled = enabled
                @filters = Array.new
                @filters_out = Array.new
                @received_events = Array.new
            end

            # Show only events matching this pattern
            #
            # Patterns are OR-ed (i.e. an event is displayed if it matches at
            # least one pattern)
            def filter(pattern)
                @filters << pattern
            end

            # Hide events that match this pattern
            #
            # Patterns are OR-ed (i.e. an event is displayed if it matches at
            # least one pattern)
            def filter_out(pattern)
                @filters_out << pattern
            end

            # Remove all filters
            def clear_filters
                @filters.clear
            end

            # Test if an event matches the filters setup
            #
            # It returns a match if no filters have been added
            def matches_filter?(event)
                if @filters.empty? || @filters.any? { |pattern| pattern === event.to_s }
                    @filters_out.empty? || @filters_out.none? { |pattern| pattern === event.to_s }
                end
            end

            # This is the API used by Roby to actually log events
            def dump(m, time, *args)
                received_events << [m, time, *args]
                if enabled? && matches_filter?(m)
                    @io.puts "#{time.to_hms} #{m}(#{args.map(&:to_s).join(", ")})"
                end
            end

            def has_received_event?(expected_m, *expected_args)
                received_events.any? do |m, time, args|
                    if args.size == expected_args.size
                        [m, *args].zip([expected_m, *args]).all? do |v, expected|
                            expected === v
                        end
                    end
                end
            end
        end
    end
end

