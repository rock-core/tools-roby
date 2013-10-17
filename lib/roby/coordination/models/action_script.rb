module Roby
    module Coordination
        module Models
            module ActionScript
                include Models::Actions
                include Models::Script

                def method_missing(m, *args, &block)
                    if m.to_s =~ /(.*)!/
                        action_name = $1
                        execute(task(send(action_name, *args, &block)))
                    else super
                    end
                end
            end
        end
    end
end

