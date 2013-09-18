$LOAD_PATH.unshift File.expand_path(File.join('..', '..', 'lib'), File.dirname(__FILE__))
require 'roby/test/common'
require 'roby/tasks/simple'

describe Roby::Actions::Action do
    include Roby::SelfTest

    it "can be droby-marshalled" do
        task_m = Roby::Task.new_submodel
        interface_m = Roby::Actions::Interface.new_submodel do
            describe('action').
                returns(task_m).
                required_arg('test')
            def an_action(arguments); end
        end

        action = interface_m.an_action('test' => task_m)
        dump = action.droby_dump(nil)
        dump = Marshal.dump(dump)
        loaded = Marshal.load(dump).proxy(Roby::Distributed::DumbManager)
        assert_same action.model, loaded.model
        assert_equal action.arguments, loaded.arguments
    end
end

