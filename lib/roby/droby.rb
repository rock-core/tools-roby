# frozen_string_literal: true

require "roby/droby/identifiable"
require "roby/droby/v5"
require "roby/droby/droby_id"
require "roby/droby/peer_id"
require "roby/droby/remote_droby_id"
require "roby/droby/object_manager"
require "roby/droby/marshal"
require "roby/droby/event_logging"
require "roby/droby/null_event_logger"

module Roby
    module DRoby
        extend Logger::Hierarchy
        extend Logger::Forward
    end
end
