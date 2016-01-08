module Roby
    module DRoby
        # Exception raised when trying to resolve a sibling for which we
        # don't have any information
        class UnknownSibling < RuntimeError
        end

        # Exception raised when an attempt to resolve a marshalled object into a
        # local object failed
        class NoLocalObject < RuntimeError
        end
    end
end

