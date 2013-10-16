module Roby
    module Interface
        # An interface client using TCP that provides reconnection capabilities
        # as well as proper formatting of the information
        class ShellClient < BasicObject
            # @return [String] the host we are connecting to
            attr_reader :host
            # @return [Integer] the port we are connecting to
            attr_reader :port
            # @return [Client,nil] the socket used to communicate to the server,
            #   or nil if we have not managed to connect yet
            attr_reader :client
            # @return [Mutex] the shell requires multi-threading access, this is
            #   the mutex to protect when required
            attr_reader :mutex

            def initialize(host, port)
                @host, @port = host, port
                @mutex = Mutex.new
                connect
            end

            def connect(retry_period = 0.5)
                retry_warning = false
                begin
                    @client = ::Roby::Interface.connect_with_tcp_to(host, port)
                rescue ConnectionError, ComError => e
                    if retry_period
                        if e.kind_of?(ComError)
                            Roby::Interface.warn "failed handshake with #{host}:#{port}, retrying ..."
                        elsif !retry_warning
                            Roby::Interface.warn "cannot connect to #{host}:#{port}, retrying every #{retry_period} seconds..."
                            retry_warning = true
                        end
                        sleep retry_period
                        retry
                    else raise
                    end
                end
            end

            def close
                client.close
                @client = nil
            end

            def poll
                super
            end

            def actions
                pp client.actions
                nil
            end

            def retry_on_com_error
                yield
            rescue ComError
                Roby::Interface.warn "Lost communication with remote, retrying command after reconnection"
                connect
                retry
            end

            def describe(matcher)
                if matcher.kind_of?(Roby::Actions::Action)
                    pp matcher.model
                elsif matcher.kind_of?(Roby::Actions::Model::Action)
                    pp matcher
                else
                    client.find_all_actions_matching(matcher).each do |act|
                        pp act
                    end
                end
                nil
            end

            def call(options, m, *args)
                options = Kernel.validate_options options, :retry => false
                if options[:retry]
                    options = options.merge(:retry => false)
                    retry_on_com_error do
                        return call options, m, *args
                    end
                else
                    @mutex.synchronize do
                        client.send(m, *args)
                    end
                end
            end

            def format_notification(kind, job_id, job_name, *args)
                "[#{job_id}] #{job_name}: #{kind}"
            end

            def format_exception(kind, error, *args)
                color = if kind == ExecutionEngine::EXCEPTION_FATAL then [:red]
                        elsif kind == ExecutionEngine::EXCEPTION_NONFATAL then [:magenta]
                        else []
                        end
                msg = error.exception.formatted_message || [error.exception.message] || []
                msg = msg.dup
                if msg[0]
                    msg[0] = Roby.console.color(msg[0], :bold, *color)
                end
                puts msg.join("\n")
                nil
            end

            def wtf?
                msg = []
                @mutex.synchronize do
                    client.notification_queue.each do |kind, job_id, job_name, *args|
                        msg << format_notification(kind, job_id, job_name, *args)
                    end
                    client.exception_queue.each do |kind, exception, tasks|
                        msg << format_exception(kind, exception, tasks)
                    end
                    client.notification_queue.clear
                    client.exception_queue.clear
                end
                puts msg.join("\n")
                nil
            end

            def method_missing(m, *args, &block)
                if act = client.find_action_by_name(m.to_s)
                    Roby::Actions::Action.new(act, *args)
                else
                    call Hash[], m, *args
                end
            rescue ComError
                Roby::Interface.warn "Lost communication with remote, will not retry the command after reconnection"
                mutex.synchronize do
                    connect
                end
            rescue Interrupt
                Roby::Interface.warn "Interrupted"
            end
        end
    end
end
