# frozen_string_literal: true

# List of backports waiting to be accepted in the backports gem
class Set
    # Defined in 2.4.0
    #
    # Hash#compare_by_identity appeared in ruby 1.9.1
    def compare_by_identity
        @hash.compare_by_identity
    end

    # Defined in 2.4.0
    #
    # Hash#compare_by_identity? appeard in ruby 1.9.1
    def compare_by_identity?
        @hash.compare_by_identity?
    end
end
