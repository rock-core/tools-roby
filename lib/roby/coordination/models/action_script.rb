module Roby
    module Coordination
        module Models
            # Definition of model-level functionality for action scripts
            #
            # Action scripts are sequential representations of action
            # coordinations. Each step is a script instruction (created with one
            # of the API calls in {Script}) whose argument is a {Task} object.
            # The {Task} object represents the actual work that will be done
            # there
            #
            # Action script models are usually created through an action
            # interface with Interface#action_script. The script
            # model can then be retrieved using
            # {Actions::Models::Action#coordination_model}.
            #
            # @example creating an action script
            #   class Main < Roby::Actions::Interface
            #     action_script 'example_action' do
            #       # Start moving at 0.1 m/s until we move more than 0.1m
            #       move_task = task move(speed: 0.1)
            #       d_monitor = task monitor_movement_threshold(d: 0.1)
            #       d_monitor.depends_on move_task
            #       execute d_monitor
            #
            #       # Then, once we're done with that, stand still for 20s
            #       stand_task = task move(speed: 0)
            #       t_monitor  = task monitor_time_threshold(t: 20) 
            #       t_monitor.depends_on stand_task
            #       execute t_monitor
            #
            #       # Finally, announce the success
            #       emit success_event
            #     end
            #   end
            #
            # @example retrieving a script model from an action
            #   Main.find_action_by_name('example_action').coordination_model
            module ActionScript
                include Models::Actions
                include Models::Script

                def method_missing(m, *args, &block)
                    if m.to_s =~ /(.*)!/
                        action_name = $1
                        task = task(send(action_name, *args, &block))
                        task.name = action_name
                        execute(task)
                    else super
                    end
                end
            end
        end
    end
end

