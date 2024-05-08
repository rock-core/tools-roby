# frozen_string_literal: true

require "roby/interface/async"
require "roby/interface/v1/async/log"

Roby.warn_deprecated(
    "require \"roby/interface/async/log\" is deprecated, use the versioned interface " \
    "API instead, that is roby/interface/v1/async/log and Roby::Interface::V1::Async::Log"
)
