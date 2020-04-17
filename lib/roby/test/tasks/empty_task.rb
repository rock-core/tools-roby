# frozen_string_literal: true

module Roby
    module Test
        class EmptyTask < Roby::Task
            terminates
            forward start: :success
        end
    end
end
