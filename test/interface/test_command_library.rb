# frozen_string_literal: true

require "roby/test/self"
require "roby/interface"

module Roby
    module Interface
        describe CommandLibrary do
            it "defines instance methods to given access to subcommands" do
                library_m   = Class.new(CommandLibrary)
                interface_m = Class.new(CommandLibrary)
                interface_m.subcommand "test", library_m
                interface = interface_m.new(Roby.app)
                assert_kind_of library_m, interface.test
            end
        end
    end
end
