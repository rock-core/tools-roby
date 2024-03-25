# frozen_string_literal: true

Roby.warn_deprecated(
    "require \"roby/interface/async\" is deprecated, require the versioned "\
    "roby/interface/v1/async or roby/interface/v2/async instead, and use the "\
    "explicitly versioned namespace"
)

if ENV["ROBY_STRICT_INTERFACE_VERSION"] == "1"
    raise LoadError,
          "roby/interface/async not available because "\
          "ROBY_STRICT_INTERFACE_VERSION is set"
end

module Roby
    module Interface
        # @deprecated asynchronous connection to e remote Roby instance
        #
        # This is the old v1 module. Require v1/async and v2/async, and use
        # the versioned module directly instead
        module Async
            extend Logger::Hierarchy
        end
    end
end

require "roby/interface/v1/async"

module Roby
    module Interface
        module Async # :nodoc:
            include V1::Async
        end
    end
end
