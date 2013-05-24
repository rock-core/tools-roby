module Roby
    # Namespace for all query and matching-related functionality
    module Queries
    end
end

require 'roby/queries/matcher_base'
require 'roby/queries/index'
require 'roby/queries/plan_object_matcher'
require 'roby/queries/task_matcher'
require 'roby/queries/query'
require 'roby/queries/and_matcher'
require 'roby/queries/not_matcher'
require 'roby/queries/or_matcher'
