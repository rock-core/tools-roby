# frozen_string_literal: true

module Roby
    module Interface
        module Protocol
            Action = Struct.new :model, :arguments
            ActionModel = Struct.new(
                :planner_name, :name, :doc, :arguments, :advanced, keyword_init: true
            ) do
                def advanced?
                    advanced
                end
            end

            ActionArgument =
                Struct.new :name, :doc, :required, :default, :example, keyword_init: true
            Task = Struct.new(:id, :model, :arguments, keyword_init: true)
            Error = Struct.new(:message, :backtrace, keyword_init: true)
            VoidClass = Class.new
            Void = VoidClass.new.freeze
        end
    end
end
