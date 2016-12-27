class Object
    def droby_marshallable?; true end
end

module Roby
    module DRoby
        module Unmarshallable
            def droby_marshallable?; false end
        end
    end
end

