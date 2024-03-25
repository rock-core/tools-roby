# frozen_string_literal: true

Roby.warn_deprecated(
    "require \"roby/interface/async\" is deprecated, use the properly versioned "\
    "require and module (e.g. \"roby/interface/v1/casync\" and Interface::V1::Async)"
)

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
