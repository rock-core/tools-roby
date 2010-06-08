require 'roby/tasks/simple'
module Roby
    module Test
        Roby.warn "Roby::Test::SimpleTask is deprecated, use Roby::Tasks::Simple instead"
        backtrace = caller
        Roby.warn "  loaded from #{backtrace[0]}"
        backtrace[1..-1].each do |backtrace_line|
            Roby.warn "        #{backtrace_line}"
        end

        SimpleTask = Roby::Tasks::Simple
    end
end

