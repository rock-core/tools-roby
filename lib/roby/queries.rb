module Roby
    # Namespace for all query and matching-related functionality
    module Queries
    end
end

require 'roby/queries/any'
require 'roby/queries/matcher_base'
require 'roby/queries/index'
require 'roby/queries/plan_object_matcher'
require 'roby/queries/task_matcher'
require 'roby/queries/task_event_generator_matcher'
require 'roby/queries/query'
require 'roby/queries/and_matcher'
require 'roby/queries/not_matcher'
require 'roby/queries/or_matcher'

require 'roby/queries/localized_error_matcher'
require 'roby/queries/execution_exception_matcher'

