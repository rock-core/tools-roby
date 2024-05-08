# frozen_string_literal: true

require "roby"

Roby.warn_deprecated(
    "require \"roby/interface\" is deprecated, require the versioned " \
    "v1/interface or v2/interface instead, and use the explicitly " \
    "versioned namespace"
)

if ENV["ROBY_STRICT_INTERFACE_VERSION"] == "1"
    raise LoadError,
          "roby/interface not available because ROBY_STRICT_INTERFACE_VERSION is set"
end

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
