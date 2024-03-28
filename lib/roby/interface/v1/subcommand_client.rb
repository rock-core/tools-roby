# frozen_string_literal: true

module Roby
    module Interface
        module V1
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
                # @return [Hash<String,Command>] the set of commands on this subcommand
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

                def async_call(path, m, *args, &block)
                    parent.async_call([name] + path, m, *args, &block)
                end

                def find_subcommand_by_name(m)
                    @commands[m.to_s]
                end

                def has_command?(m)
                    @commands.has_key?(m.to_s)
                end

                def method_missing(m, *args, &block)
                    if (sub = find_subcommand_by_name(m))
                        SubcommandClient.new(self, m, sub.description, sub.commands)
                    elsif (match = /^async_(.*)$/.match(m.to_s))
                        async_call([], match[1].to_sym, *args, &block)
                    else
                        call([], m, *args)
                    end
                end
            end
        end
    end
end
