# frozen_string_literal: true

module Roby
    module DRoby
        class IOEventLogger
            def initialize(filter: ->(_) { true }, out: STDOUT)
                @filter = filter
                @out = STDOUT
            end

            def log_timepoints?
                true
            end

            Event = Struct.new :m, :time, :args do
                def pretty_print(pp)
                    pp.text "#{Roby.format_time(time)} #{m}"
                    pp.nest(2) do
                        args.each do |obj|
                            pp.breakable
                            obj.pretty_print(pp)
                        end
                    end
                end
            end

            def display_event(m, time, args)
                return unless @filter === m

                @out.puts PP.pp(Event.new(m, time, args), +"")
            end

            def dump(m, time, *args)
                display_event(m, time, args)
            end

            def dump_timepoint(m, time, *args)
                display_event(m, time, args)
            end

            def close; end

            def log_queue_size
                0
            end

            def dump_time
                0
            end

            def flush_cycle(m, *args); end
        end
    end
end
