require 'roby/state/state'

module Roby
    class Environment < ExtendableStruct
        def initialize
            super
            @maps = Hash.new
        end

        # A kind => source hash where 'kind' is the map type
        # and 'source' where it is located
        attr_reader :maps
    end
    State.environment = Environment.new
end

