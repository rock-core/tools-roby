module Roby
    module Queries
        # Implementation of a singleton object that matches no other object
        module None
            # @return [Boolean] match operator, always returns false
            def self.===(other)
                false
            end
        end

        # @return [None] an object that matches nothing
        def self.none
            None
        end
    end
end


