require 'roby/tasks/simple'
module Roby
    module Test
        Roby.warn "Roby::Test::SimpleTask is deprecated, use Roby::Tasks::Simple instead"
        backtrace = caller
        backtrace.delete_if { |l| l =~ /require/ }
        Roby.warn "  loaded from #{backtrace[0]}"

        SimpleTask = Roby::Tasks::Simple
    end
end

