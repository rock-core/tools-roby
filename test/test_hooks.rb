# frozen_string_literal: true

require "roby/test/self"

module Roby
    describe Hooks do
        it "registers a hook for the given event" do
            obj = klass.new
            mock = flexmock
            mock.should_receive(:called).once
            obj.on_test { mock.called }
            obj.run_hook :on_test
        end
        it "returns a disposable that deregister the hook" do
            obj = klass.new
            mock = flexmock
            mock.should_receive(:called).never
            obj.on_test { mock.called }.dispose
            obj.run_hook :on_test
        end

        def klass
            @klass ||= Class.new do
                include Hooks
                include Hooks::InstanceHooks

                define_hook :on_test
            end
        end
    end
end
