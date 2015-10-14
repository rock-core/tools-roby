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
                @pending_non_executable_tasks = Set.new
                @called_generators = Set.new
                @non_scheduled_tasks = Hash.new { |h, k| h[k] = Set.new }
            end

            # Add information contained in 'state' to this object
            def merge!(state)
                pending_non_executable_tasks.merge(state.pending_non_executable_tasks)
                called_generators.merge(state.called_generators)
                non_scheduled_tasks.merge!(state.non_scheduled_tasks) do |task, msg0, msg1|
                    msg0.merge(msg1)
                end
            end

            # Formats a message stored in {#non_scheduled_tasks} into a plain
            # string
            def self.format_message_into_string(msg, *args)
                args.each_with_index.inject(msg) do |msg, (a, i)|
                    a = if a.respond_to?(:map)
                            a.map(&:to_s).join(", ")
                        else a.to_s
                        end
                    msg.gsub "%#{i + 1}", a
                end
            end
        end
    end
end


