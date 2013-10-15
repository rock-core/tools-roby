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

            def initialize(host, port)
                @host, @port = host, port
                connect
            end

            def connect(retry_period = 0.5)
                retry_warning = false
                begin
                    @client = ::Roby::Interface.connect_with_tcp_to(host, port)
                    Roby::Interface.warn "connected to #{host}:#{port}"
                rescue ConnectionError, ComError => e
                    if e.kind_of?(ComError)
                        Roby::Interface.warn "failed handshake with #{host}:#{port}, retrying ..."
                    elsif !retry_warning
                        Roby::Interface.warn "cannot connect to #{host}:#{port}, retrying every #{retry_period} seconds..."
                        retry_warning = true
                    end
                    sleep retry_period
                    retry
                end
            end

            def close
                client.close
                @client = nil
            end

            def poll
                super
            end

            def method_missing(m, *args, &block)
                client.send(m, *args, &block)
            end
        end
    end
end
