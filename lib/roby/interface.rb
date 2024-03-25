# frozen_string_literal: true

require "roby"
require "roby/interface/core"
require "roby/interface/v1"

module Roby
    module Interface
        include V1

        def self.connect_with_tcp_to(
            host, port = DEFAULT_PORT,
            marshaller: DRoby::Marshal.new(auto_create_plans: true),
            handshake: %i[actions commands]
        )
            V1.connect_with_tcp_to(
                host, port, marshaller: marshaller, handshake: handshake
            )
        end
    end
end
