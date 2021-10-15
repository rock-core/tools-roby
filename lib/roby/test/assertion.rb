# frozen_string_literal: true

module Roby
    module Test
        class Assertion < MiniTest::Assertion
            attr_reader :original_error

            def initialize(original_error)
                super()

                @original_error = original_error
            end

            def message
                [super].concat(Roby.format_exception(original_error)).join("\n")
            end
        end
    end
end
