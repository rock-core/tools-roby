module Roby
    module Coordination
        module Models
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

