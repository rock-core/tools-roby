module Roby
    module Interface
        # The client-side object that allows to access an interface (e.g. a Roby
        # app) from another process than the Roby controller
        class Client < BasicObject
            # @return [DRobyChannel] the IO to the server
            attr_reader :io
            # @return [Array<Roby::Actions::Model::Action>] set of known actions
            attr_reader :actions
            # @return [Hash] the set of available commands
            attr_reader :commands
            # @return [Array<Integer,Array>] list of existing notifications. The
            #   integer is an ID that can be used to refer to the notification.
            #   It is always growing and will never collide with an exception ID
            attr_reader :notification_queue
            # @return [Array<Integer,Array>] list of existing exceptions. The
            #   integer is an ID that can be used to refer to the exception.
            #   It is always growing and will never collide with a notification ID
            attr_reader :exception_queue

            # @param [DRobyChannel] a channel to the server
            def initialize(io, id)
                @io = io
                @message_id = 0
                @notification_queue = Array.new
                @exception_queue = Array.new

                @actions, @commands = handshake(id)
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

            # Reads what is available on the given IO and processes the message
            #
            # @param [#read_packet] io packet-reading object
            # @return [Boolean] false if no packet has been processed, and true
            #   otherwise
            def read_and_process_packet(io)
                m, *args = io.read_packet
                if m == :bad_call
                    raise args.first
                elsif m == :reply
                    yield args.first
                elsif m == :notification
                    push_notification(*args)
                elsif m == :exception
                    push_exception(*args)
                elsif m
                    raise ProtocolError, "unexpected reply from #{io}: #{m} (#{args.map(&:to_s).join(",")})"
                else return false
                end
                true
            end

            def poll(expected_count = 0)
                result = nil
                timeout = if expected_count > 0 then nil
                          else 0
                          end

                while IO.select([io], [], [], timeout)
                    done_something = true
                    while done_something
                        done_something = read_and_process_packet(io) do |reply_value|
                            if result
                                raise ArgumentError, "got more than one reply in a single poll call"
                            end
                            result = reply_value
                            expected_count -= 1
                        end
                    end
                    if expected_count <= 0
                        timeout = 0
                    end
                end
                result
            end

            def allocate_message_id
                @message_id += 1
            end

            def push_notification(kind, job_id, job_name, *args)
                notification_queue.push [allocate_message_id, [kind, job_id, job_name, *args]]
            end

            def has_notifications?
                !notification_queue.empty?
            end

            def pop_notification
                notification_queue.pop
            end

            def push_exception(kind, error, tasks)
                exception_queue.push [allocate_message_id, [kind, error, tasks]]
            end

            def has_exceptions?
                !exception_queue.empty?
            end

            def pop_exception
                exception_queue.pop
            end

            def call(path, m, *args)
                if m.to_s =~ /(.*)!$/
                    action_name = $1
                    if find_action_by_name(action_name)
                        call([], :start_job, action_name, *args)
                    else raise ArgumentError, "there is no action called #{action_name}"
                    end
                else
                    io.write_packet([path, m, *args])
                    poll(1)
                end
            end

            def reload_actions
                @actions = call(:reload_actions)
            end

            def find_subcommand_by_name(name)
                commands[name]
            end

            def method_missing(m, *args)
                if m.to_s =~ /(.*)!$/
                    action_name = $1
                    if act = find_action_by_name(action_name)
                        call(:start_job, action_name, *args)
                    else raise ArgumentError, "there are is no action called #{action_name}"
                    end

                else call([], m, *args)
                end
            end
        end
    end
end

