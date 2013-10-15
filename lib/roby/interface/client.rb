module Roby
    module Interface
        # The client-side object that allows to access an interface (e.g. a Roby
        # app) from another process than the Roby controller
        class Client < BasicObject
            # @return [DRobyChannel] the IO to the server
            attr_reader :io
            # @return [Array<Roby::Actions::Model::Action>] set of known actions
            attr_reader :actions

            # @param [DRobyChannel] a channel to the server
            def initialize(io, id)
                @io = io

                handshake(id)
                
                # Get the list of existing actions so that we can validate them
                # in #method_missing
                @actions = call(:actions)
            end

            def to_io
                io.to_io
            end

            def find_action_by_name(name)
                actions.find { |act| act.name == name }
            end

            def find_all_actions_matching(matcher)
                actions.find_all { |act| matcher === act.name }
            end

            def poll(expected_count = 0)
                result = nil
                timeout = if expected_count > 0 then nil
                          else 0.01
                          end

                while IO.select([io], [], [], timeout)
                    m, *args = io.read_packet
                    if m == :bad_call
                        raise args.first
                    elsif m == :reply
                        if result
                            raise ArgumentError, "got more than one reply in a single poll call"
                        end
                        result = args.first
                        expected_count -= 1
                    elsif m == :exception
                        push_exception(*args)
                    elsif m
                        raise ProtocolError, "unexpected reply from #{io}: #{m} (#{args.map(&:to_s).join(",")})"
                    end
                    if expected_count <= 0
                        timeout = 0.01
                    end
                end
                result
            end

            def push_exception(kind, error, tasks)
                exception_queue.push [kind, error, tasks]
            end

            def has_exceptions?
                !exception_queue.empty?
            end

            def pop_exception
                exception_queue.pop
            end

            def call(*args)
                io.write_packet(args)
                poll(1)
            end

            def reload_actions
                call(:reload_actions)
                @actions = call(:actions)
            end

            def help
                call(:help)
            end

            def method_missing(m, *args)
                if m.to_s =~ /!$/
                    action_name = $'
                    if actions.find { |act| act.name == action_name }
                        call(:start, $', *args)
                    else raise ArgumentError, "there are is no action called #{action_name}"
                    end

                else call(m, *args)
                end
            end
        end
    end
end

