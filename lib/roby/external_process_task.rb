require 'roby/tasks/external_process'
module Roby
    Roby.warn "Roby::ExternalProcessTask is deprecated, use Roby::Tasks::ExternalProcess instead"

    ExternalProcessTask = Roby::Tasks::ExternalProcess
end

