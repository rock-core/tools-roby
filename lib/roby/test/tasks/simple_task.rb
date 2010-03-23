require 'roby/tasks/simple'
module Roby
    module Test
        Roby.warn "Roby::Test::SimpleTask is deprecated, use Roby::Tasks::Simple instead"
        SimpleTask = Roby::Tasks::Simple
    end
end

