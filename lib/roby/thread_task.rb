require 'roby/tasks/thread'
module Roby
    Roby.warn "Roby::ThreadTask is deprecated, use Roby::Tasks::Thread instead"

    ThreadTask = Roby::Tasks::Thread
end


