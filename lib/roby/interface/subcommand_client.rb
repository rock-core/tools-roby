module Roby
    module Interface
        # Representation of a subcommand on {Interface} on the shell side
        class SubcommandClient
            # @return [ShellClient,ShellSubcommand] the parent shell /
            #   subcommand
            attr_reader :parent
            # @return [
            # @return [String] the subcommand name
            attr_reader :name
            # @return [String] the subcommand description
            attr_reader :description
            # @return [String] the set of commands on this subcommand
            attr_reader :commands

            def initialize(parent, name, description, commands)
                @parent, @name, @description, @commands =
                    parent, name, description, commands
            end

            def call(path, m, *args)
                parent.call([name] + path, m, *args)
            end

            def path
                parent.path + [name]
            end

            def method_missing(m, *args)
                parent.call([name], m, *args)
            end
        end
    end
end

