module Roby
    module Schedulers
        # Objects representing the reports from a scheduler object
        #
        # They are saved in logs, and can also be listened to through
        # {Interface::Interface}
        class State
            # Tasks that are pending in the plan, but are not executable
            attr_accessor :pending_non_executable_tasks
            # The list of event generators triggered by the scheduler
            #
            # @return [EventGenerator]
            attr_accessor :called_generators
            # The list of tasks that have been considered for scheduling, but
            # could not be scheduled, along with the reason
            #
            # @return [{Task=>[String,Array]}] a mapping from the task that was
            #   not scheduled, to a list of messages and objects. The message
            #   can contain %N placeholders which will be replaced by the
            #   corresponding element from the array
            attr_accessor :non_scheduled_tasks

            def initialize
                @pending_non_executable_tasks = Array.new
                @called_generators = Array.new
                @non_scheduled_tasks = Hash.new { |h, k| h[k] = Array.new }
            end
        end
    end
end


