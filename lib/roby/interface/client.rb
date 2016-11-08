module Roby
    module Interface
        # The client-side object that allows to access an interface (e.g. a Roby
        # app) from another process than the Roby controller
        class Client
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

            # @return [Integer] index of the last processed cycle
            attr_reader :cycle_index
            # @return [Time] time of the last processed cycle
            attr_reader :cycle_start_time

            # Create a client endpoint to a Roby interface [Server]
            #
            # @param [DRobyChannel] io a channel to the server
            # @param [String] id a unique identifier for this client
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

            # Whether the communication channel to the server is closed
            def closed?
                io.closed?
            end

            # Close the communication channel
            def close
                io.close
            end

            # The underlying IO object
            def to_io
                io.to_io
            end

            # Tests whether the interface has an action with that name
            def has_action?(name)
                !!find_action_by_name(name)
            end

            # Find an action by its name
            #
            # This is a local operation using the information gathered at
            # connection time
            #
            # @param [String] name the name of the action to look for
            # @return [Actions::Models::Action,nil]
            def find_action_by_name(name)
                actions.find { |act| act.name == name }
            end

            # Finds all actions whose name matches a pattern
            #
            # @param [#===] matcher the matching object (usually a Regexp or
            #   String)
            # @return [Array<Actions::Models::Action>]
            def find_all_actions_matching(matcher)
                actions.find_all { |act| matcher === act.name }
            end

            # @api private
            #
            # Process a message as received on {#io}
            #
            # @return [Boolean] whether the message was a cycle_end message
            def process_packet(m, *args)
                if m == :cycle_end
                    @cycle_index, @cycle_start_time = *args
                    return true
                end

                if m == :bad_call
                    e = args.first
                    raise e, e.message, (e.backtrace + caller)
                elsif m == :reply
                    yield args.first
                elsif m == :job_progress
                    queue_job_progress(*args)
                elsif m == :notification
                    queue_notification(*args)
                elsif m == :exception
                    queue_exception(*args)
                else
                    raise ProtocolError, "unexpected reply from #{io}: #{m} (#{args.map(&:to_s).join(",")})"
                end
                false
            end

            # Wait until there is data to process on the IO channel
            #
            # @param [Numeric,nil] timeout a timeout after which the method
            #   will return. Use nil for no timeout
            # @return [Boolean] falsy if the timeout was reached, true
            #   otherwise
            def wait(timeout: nil)
                io.read_wait(timeout: timeout)
            end

            # Polls for new data on the IO channel
            #
            # @return [Object] a call reply
            # @raise [ComError] if the link seem to be broken
            # @raise [ProtocolError] if some errors happened when validating the
            #   protocol
            def poll(expected_count = 0)
                result = nil
                timeout = if expected_count > 0 then nil
                          else 0
                          end

                has_cycle_end = false
                while packet = io.read_packet(timeout)
                    has_cycle_end = process_packet(*packet) do |reply_value|
                        if result
                            raise ProtocolError, "got more than one reply in a single poll call"
                        end
                        result = reply_value
                        expected_count -= 1
                    end

                    if expected_count <= 0
                        break if has_cycle_end
                        timeout = 0
                    end
                end
                return result, has_cycle_end
            end

            # @api private
            #
            # Allocation of unique IDs for notification messages
            def allocate_message_id
                @message_id += 1
            end

            # @api private
            #
            # Push a job notification to {#job_progress_queue}
            #
            # See the yield parameters of {Interface#on_job_notification} for
            # the overall argument format.
            def queue_job_progress(kind, job_id, job_name, *args)
                job_progress_queue.push [allocate_message_id, [kind, job_id, job_name, *args]]
            end

            # Whether some job progress information is currently queued
            def has_job_progress?
                !job_progress_queue.empty?
            end

            # Remove and return the oldest job information message
            #
            # @return [(Integer,Array)] a unique and monotonically-increasing
            #   message ID and the arguments to job progress as specified on
            #   {Interface#on_job_notification}.
            def pop_job_progress
                job_progress_queue.shift
            end

            # @api private
            #
            # Push a generic notification to {#notification_queue}
            def queue_notification(source, level, message)
                notification_queue.push [allocate_message_id, [source, level, message]]
            end

            # Whether some generic notifications have been queued
            def has_notifications?
                !notification_queue.empty?
            end

            # Remove and return the oldest generic notification message
            #
            # @return [(Integer,Array)] a unique and monotonically-increasing
            #   message ID and the generic notification information as specified
            #   by (Application#notify)
            def pop_notification
                notification_queue.shift
            end

            # @api private
            #
            # Push an exception notification to {#exception_queue}
            #
            # It can be retrieved with {#pop_exception}
            #
            # See the yield parameters of {Interface#on_exception} for
            # the overall argument format.
            def queue_exception(kind, error, tasks, job_ids)
                exception_queue.push [allocate_message_id, [kind, error, tasks, job_ids]]
            end

            # Whether some exception notifications have been queued
            def has_exceptions?
                !exception_queue.empty?
            end

            # Remove and return the oldest exception notification
            #
            # @return [(Integer,Array)] a unique and monotonically-increasing
            #   message ID and the generic notification information as specified
            #   by (Interface#on_exception)
            def pop_exception
                exception_queue.shift
            end

            # Method called when trying to start an action that does not exist
            class NoSuchAction < NoMethodError; end

            # Start the given job within the batch
            #
            # @param [Symbol] action_name the action name
            # @param [Hash<Symbol,Object>] arguments the action arguments
            #
            # @raise [NoSuchAction] if the requested action does not exist
            def start_job(action_name, **arguments)
                if find_action_by_name(action_name)
                    call([], :start_job, action_name, arguments)
                else raise NoSuchAction, "there is no action called #{action_name} on #{self}"
                end
            end

            # @api private
            #
            # Call a method on the interface or on one of the interface's
            # subcommands
            #
            # @param [Array<String>] path path to the subcommand. Empty means on
            #   the interface object itself.
            # @param [Symbol] m command or action name. Actions are always
            #   formatted as action_name!
            # @param [Object] args the command or action arguments
            # @return [Object] the command result, or -- in the case of an
            #   action -- the job ID for the newly created action
            def call(path, m, *args)
                if m.to_s =~ /(.*)!$/
                    action_name = $1
                    start_job(action_name, *args)
                else
                    io.write_packet([path, m, *args])
                    result, _ = poll(1)
                    result
                end
            end

            # @api private
            #
            # Object used to gather commands in a batch
            #
            # @see Client#create_batch Client#process_batch
            class BatchContext < BasicObject
                # Creates a new batch context
                #
                # @param [Object] context the underlying interface object
                def initialize(context)
                    @context = context
                    @calls = ::Array.new
                end

                # The set of operations that have been gathered so far
                def __calls
                    @calls
                end

                # Pushes an operation in the batch
                def __push(path, m, *args)
                    @calls << [path, m, *args]
                end

                # Start the given job within the batch
                #
                # Note that as all batch operations, order does NOT matter
                #
                # @raise [NoSuchAction] if the action does not exist
                def start_job(action_name, *args)
                    if @context.has_action?(action_name)
                        __push([], :start_job, action_name, *args)
                    else
                        ::Kernel.raise ::Roby::Interface::Client::NoSuchAction, "there is no action called #{action_name} on #{@context}"
                    end
                end

                # Drop the given job within the batch
                #
                # Note that as all batch operations, order does NOT matter
                def drop_job(job_id)
                    __push([], :drop_job, job_id)
                end

                # Kill the given job within the batch
                #
                # Note that as all batch operations, order does NOT matter
                def kill_job(job_id)
                    __push([], :kill_job, job_id)
                end

                # @api private
                #
                # Provides the action_name! syntax to start jobs
                def method_missing(m, *args)
                    if m.to_s =~ /(.*)!$/
                        start_job($1, *args)
                    else
                        ::Kernel.raise ::NoMethodError.new(m), "#{m} either does not exist, or is not supported in batch context (only starting and killing jobs is)"
                    end
                end

                # Process the batch and return the list of return values for all
                # the calls in {#__calls}
                def __process
                    @context.process_batch(self)
                end
            end

            Job = Struct.new :job_id, :state, :placeholder_task, :task do
                def action_model
                    task.action_model
                end
            end

            # Enumerate the current jobs
            def each_job
                return enum_for(__method__) if !block_given?
                jobs.each do |job_id, (job_state, placeholder_task, job_task)|
                    yield(Job.new(job_id, job_state, placeholder_task, job_task))
                end
            end

            # Find all the jobs that match the given action name
            #
            # @return [Array<Job>]
            def find_all_jobs_by_action_name(action_name)
                each_job.find_all do |j|
                    j.action_model.name == action_name
                end
            end

            # Create a batch context
            #
            # Messages sent to the returned object are validated as much as
            # possible and gathered in a list. Call {#process_batch} to send all
            # the gathered calls at once to the remote server
            #
            # @return [BatchContext]
            def create_batch
                BatchContext.new(self)
            end

            # Send all commands gathered in a batch for processing on the remote
            # server
            #
            # @param [BatchContext] batch
            # @return [Array] the return values of each of the calls gathered in
            #   the batch
            def process_batch(batch)
                call([], :process_batch, batch.__calls)
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

