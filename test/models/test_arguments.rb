# frozen_string_literal: true

require "roby/test/self"

module Roby
    module Models
        describe Arguments do
            attr_reader :model

            before do
                @model = Class.new do
                    extend Arguments
                end
            end

            it "defines a new named argument" do
                model.argument :test
                assert model.has_argument? :test
            end

            it "does not have a default argument by default" do
                model.argument :test
                assert_nil model.default_argument(:test)
            end

            it "stores a plain default value as a DefaultArgument object" do
                model.argument :test, default: 10
                assert_equal [true, DefaultArgument.new(10)],
                             model.default_argument(:test)
            end

            it "allows to use 'nil' as a default argument value" do
                model.argument :test, default: nil
                assert_equal [true, DefaultArgument.new(nil)],
                             model.default_argument(:test)
            end

            it "stores a delayed argument value as-is" do
                default = flexmock(evaluate_delayed_argument: false)
                model.argument :test, default: default
                assert_equal [true, default],
                             model.default_argument(:test)
            end

            it "extracts the comment block as documentation by default" do
                # This is a documentation block
                model.argument :test
                assert_equal "This is a documentation block",
                             model.find_argument(:test).doc
            end

            it "allows to set the documentation programmatically as well" do
                # This is a documentation block
                model.argument :test, doc: "Programmatically"
                assert_equal "Programmatically",
                             model.find_argument(:test).doc
            end

            it "allows to set an example to required arguments" do
                # This is a documentation block
                model.argument :test, example: 42
                assert_equal 42, model.find_argument(:test).example
            end
        end
    end
end
