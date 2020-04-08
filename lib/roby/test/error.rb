# frozen_string_literal: true

module Roby
    module Test
        # Class used to wrap exceptions so that #message returns the
        # pretty-printed version of the message
        class Error < RuntimeError
            attr_reader :original_error

            def initialize(original_error)
                @original_error = original_error
            end

            def message
                [super].concat(Roby.format_exception(original_error)).join("\n")
            end
        end
    end
end
