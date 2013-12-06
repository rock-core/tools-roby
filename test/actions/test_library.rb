$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/actions'
require 'flexmock/test_unit'

class TC_Actions_Library < Test::Unit::TestCase
    include Roby::SelfTest
    include Roby::SelfTest::Assertions

    def test_action_libraries_are_registered_as_submodels_of_Library
        library = Module.new do
            action_library
        end
        assert Actions::Library.each_submodel.to_a.include?(library)
    end
end

