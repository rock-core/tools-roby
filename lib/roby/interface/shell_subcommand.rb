module Roby
    module Interface
        # Representation of a subcommand on {Interface} on the shell side
        class ShellSubcommand
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

            def call(options, path, m, *args)
                parent.call(options, [name] + path, m, *args)
            end

            def path
                parent.path + [name]
            end

            def method_missing(m, *args)
                parent.call(Hash.new, [name], m, *args)
            rescue NoMethodError => e
                if e.message =~ /undefined method .#{m}./
                    puts "invalid command name #{m}, call 'help #{path.join(".")}' for more information"
                else raise
                end
            rescue ArgumentError => e
                if e.message =~ /wrong number of arguments/ && e.backtrace.first =~ /#{m.to_s}/
                    puts e.message
                else raise
                end
            end
        end
    end
end
