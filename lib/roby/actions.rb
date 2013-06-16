module Roby
    module Actions
        extend Logger::Hierarchy
    end
end

require 'roby/actions/models/action'
require 'roby/actions/models/interface'

require 'roby/actions/action'
require 'roby/actions/interface'
require 'roby/actions/task'

require 'roby/actions/library'
