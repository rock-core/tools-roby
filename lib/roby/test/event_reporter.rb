module Roby
    module Test
        # A event-logging compatible object that is used to 
        class EventReporter
            # Whether the reporter should report anything
            attr_predicate :enabled?, true

            def initialize(io, enabled: false)
                @io = io
                @enabled = enabled
                @filters = Array.new
            end

            # Show only events matching this pattern
            #
            # Patterns are OR-ed (i.e. an event is displayed if it matches at
            # least one pattern)
            def filter(pattern)
                @filters << pattern
            end

            # Remove all filters
            def clear_filters
                @filters.clear
            end

            # Test if an event matches the filters setup
            #
            # It returns a match if no filters have been added
            def matches_filter?(event)
                @filters.empty? || @filters.any? { |pattern| pattern === event.to_s }
            end

            # This is the API used by Roby to actually log events
            def dump(m, time, *args)
                if enabled? && matches_filter?(m)
                    @io.puts "#{time.to_hms} #{m}(#{args.map(&:to_s).join(", ")})"
                end
            end
        end
    end
end

