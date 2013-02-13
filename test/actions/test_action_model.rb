$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/actions'
require 'flexmock/test_unit'

class TC_Actions_ActionModel < Test::Unit::TestCase
    include Roby::SelfTest
    include Roby::SelfTest::Assertions

    def test_it_can_be_dumped_and_loaded_as_identity
        task_m = Class.new(Roby::Task)
        interface_m = Class.new(Roby::Actions::Interface) do
            describe('action').
                returns(task_m)
            def an_action; end
        end

        action_m = interface_m.find_action_by_name('an_action')
        dump = action_m.droby_dump(nil)
        Marshal.dump(dump)
        loaded = dump.proxy(nil)
        assert_same action_m, loaded
    end
end

