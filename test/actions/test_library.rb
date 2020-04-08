# frozen_string_literal: true

require "roby/test/self"

class TC_Actions_Library < Minitest::Test
    def test_action_libraries_are_registered_as_submodels_of_Library
        library = Module.new do
            action_library
        end
        assert Actions::Library.each_submodel.to_a.include?(library)
    end
end
