module Roby
    class Task
        def self.state
            @state ||= StateFieldModel.new(self)
        end

        def state
            if @state
                return @state
            end
            @state = StateModel.new(self.class.full_state_model)
        end
    end
end

