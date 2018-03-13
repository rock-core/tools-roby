class Object
    def droby_marshallable?; true end
end

class Module
    def droby_marshallable?
        false
    end
end

module Roby
    module DRoby
        module Unmarshallable
            def droby_marshallable?; false end
        end
    end
end

