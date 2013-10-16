module Roby
    module Interface
        # An argument of a {Command}
        class CommandArgument
            # @return [Symbol] the argument name
            attr_reader :name
            # @return [Array<String>] the argument description
            attr_reader :description

            def initialize(name, description)
                @name, @description = name.to_sym, Array(description)
            end
        end
    end
end

