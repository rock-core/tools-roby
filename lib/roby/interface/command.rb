# frozen_string_literal: true

module Roby
    module Interface
        # A command on an {CommandLibrary}
        class Command
            # @return [Symbol] the command name
            attr_reader :name
            # @return [Array<String>] the command description. The first element
            #   of the array is used as a command summary
            attr_reader :description
            # @return [Hash<Symbol,CommandArgument>] the set of arguments for
            #   this command
            attr_reader :arguments

            def initialize(name, description, arguments = {})
                @name, @description, @arguments = name, Array(description), Kernel.normalize_options(arguments)
            end

            def droby_dump(peer)
                self
            end
        end
    end
end
