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
            # @return [Array<Integer,Array>] list of existing job progress
            #   information. The integer is an ID that can be used to refer to the
            #   job progress information.  It is always growing and will never
            #   collide with a job progress and exception ID
            attr_reader :job_progress_queue
            # @return [Array<Integer,Array>] list of existing notifications. The
            #   integer is an ID that can be used to refer to the notification.
            #   It is always growing and will never collide with an exception ID
            attr_reader :notification_queue
            # @return [Array<Integer,Array>] list of existing exceptions. The
            #   integer is an ID that can be used to refer to the exception.
            #   It is always growing and will never collide with a notification ID
            attr_reader :exception_queue

            # Create a client endpoint to a Roby interface [Server]
            #
            # @param [DRobyChannel] io a channel to the server
            # @param [Object] String a unique identifier for this client
            #   (e.g. host:port of the local endpoint when using TCP). It is
            #   passed to the server through {Server#handshake}
            #
            # @see Interface.connect_with_tcp_to
            def initialize(io, id)
                @io = io
                @message_id = 0
                @notification_queue = Array.new
                @job_progress_queue = Array.new
                @exception_queue = Array.new

                @actions, @commands = handshake(id)
            end

            def closed?
                io.closed?
            end

            def close
                io.close
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
            # @return [Boolean,Boolean] the first boolean indicates if a packet
            #   has been processed, the second one if it was a cycle_end message
            def read_and_process_packet(io)
                m, *args = io.read_packet
                if m == :cycle_end
                    return true, true
                end

                if m == :bad_call
                    e = args.first
                    raise e, e.message, e.backtrace
                elsif m == :reply
                    yield args.first
                elsif m == :job_progress
                    push_job_progress(*args)
                elsif m == :notification
                    push_notification(*args)
                elsif m == :exception
                    push_exception(*args)
                elsif m
                    raise ProtocolError, "unexpected reply from #{io}: #{m} (#{args.map(&:to_s).join(",")})"
                else return false
                end
                return true
            end

            # Polls for new data on the IO channel
            #
            # @raise [ComError] if the link seem to be broken
            # @return [Object] a call reply
            def poll(expected_count = 0)
                result = nil
                timeout = if expected_count > 0 then nil
                          else 0
                          end

                has_cycle_end = false
                while IO.select([io], [], [], timeout)
                    done_something = true
                    while done_something
                        done_something, has_cycle_end = read_and_process_packet(io) do |reply_value|
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
                return result, has_cycle_end
            end

            def allocate_message_id
                @message_id += 1
            end

            # Push a job notification to {#job_progress_queue}
            #
            # See the yield parameters of {Interface#on_job_notification} for
            # the overall argument format.
            def push_job_progress(kind, job_id, job_name, *args)
                job_progress_queue.push [allocate_message_id, [kind, job_id, job_name, *args]]
            end

            def has_job_progresss?
                !job_progress_queue.empty?
            end

            def pop_job_progress
                job_progress_queue.pop
            end

            def push_notification(source, level, message)
                notification_queue.push [allocate_message_id, [source, level, message]]
            end

            def has_notifications?
                !notification_queue.empty?
            end

            def pop_notification
                notification_queue.pop
            end

            # Push an exception notification to {#exception_queue}
            #
            # It can be retrieved with {#pop_exception}
            #
            # See the yield parameters of {Interface#on_exception} for
            # the overall argument format.
            def push_exception(kind, error, tasks, job_ids)
                exception_queue.push [allocate_message_id, [kind, error, tasks, job_ids]]
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
                    result, _ = poll(1)
                    if m == :start_job
                        push_job_progress(:queued, result, nil)
                    end
                    result
                end
            end

            class BatchContext < BasicObject
                def initialize(context)
                    @context = context
                    @calls = Array.new
                end

                def __calls
                    @calls
                end

                def push(path, m, *args)
                    @calls << [path, m, *args]
                end

                def method_missing(m, *args)
                    if m.to_s =~ /(.*)!$/
                        action_name = $1
                        if @context.find_action_by_name(action_name)
                            push([], :start_job, action_name, *args)
                        else raise ArgumentError, "there is no action called #{action_name}"
                        end
                    else
                        push([], m, *args)
                    end
                end

                def process
                    @context.process_batch(self)
                end
            end

            def create_batch
                BatchContext.new(self)
            end

            def process_batch(batch)
                result = call([], :process_batch, batch.__calls)
                result.each_with_index do |ret, idx|
                    if batch.__calls[idx][1] == :start_job
                        push_job_progress(:queued, ret, nil)
                    end
                end
                result
            end

            def reload_actions
                @actions = call([], :reload_actions)
            end

            def find_subcommand_by_name(name)
                commands[name]
            end

            def method_missing(m, *args)
                call([], m, *args)
            end
        end
    end
end

