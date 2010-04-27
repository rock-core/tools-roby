require 'roby/tasks/thread'
module Roby
    Roby.warn "Roby::ThreadTask is deprecated, use Roby::Tasks::Thread instead"
    backtrace = caller
    backtrace.delete_if { |l| l =~ /require/ }
    Roby.warn "  loaded from #{backtrace[0]}"

    ThreadTask = Roby::Tasks::Thread
end


