require 'roby/tasks/external_process'
module Roby
    Roby.warn "Roby::ExternalProcessTask is deprecated, use Roby::Tasks::ExternalProcess instead"
    backtrace = caller
    backtrace.delete_if { |l| l =~ /require/ }
    Roby.warn "  loaded from #{backtrace[0]}"

    ExternalProcessTask = Roby::Tasks::ExternalProcess
end

