# frozen_string_literal: true

module Roby
    module DRoby
        module Identifiable
            # The DRobyID for this object
            def droby_id
                if @__droby_remote_id__
                    @__droby_remote_id__
                elsif !frozen?
                    @__droby_remote_id__ = DRobyID.allocate
                end
            end

            def initialize_copy(old) # :nodoc:
                super
                @__droby_remote_id__ = nil
            end
        end
    end
end
