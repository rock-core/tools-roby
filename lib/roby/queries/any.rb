# frozen_string_literal: true

module Roby
    module Queries
        # Implementation of a singleton object that match any other object
        module Any
            # @return [Boolean] match operator, always returns true
            def self.===(_other)
                true
            end

            class DRoby
                def proxy(_peer)
                    Queries.any
                end
            end

            def self.droby_dump(_peer)
                DRoby.new
            end
        end

        # @return [Any] an object that matches anything
        def self.any
            Any
        end
    end
end
