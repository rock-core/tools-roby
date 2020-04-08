# frozen_string_literal: true

module Roby
    module Interface
        # Objects that hold a set of commands
        class CommandLibrary
            class << self
                extend MetaRuby::Attributes
                inherited_attribute(:command, :commands, map: true) { {} }
                inherited_attribute(:subcommand, :subcommands, map: true) { {} }

                # Declares a command for this interface
                def command(name, *info)
                    arguments = if info.last.kind_of?(Hash) then info.pop
                                else {}
                                end

                    arguments = arguments.transform_keys(&:to_sym)
                    arguments =
                        arguments.each_with_object({}) do |(arg_name, description), h|
                            h[name] = CommandArgument.new(
                                arg_name.to_sym, Array(description)
                            )
                        end

                    commands[name.to_sym] = Command.new(name.to_sym, info, arguments)
                end

                # Adds another interface object a subcommand of this command
                # interface
                #
                # @param [String] name the subcommand name. The commands will be
                #   available as name.command_name
                # @param [Model<CommandInterface>] interface the command interface model
                def subcommand(name, interface, *description)
                    subcommands[name] = [interface, description]
                    define_method name do
                        subcommands[name].first
                    end
                end
            end

            # @return [Roby::Application] the application
            attr_reader :app
            # @return [Roby::Plan] the {#app}'s plan
            def plan
                app.plan
            end

            # @return [Roby::ExecutionEngine] the {#plan}'s engine
            def execution_engine
                plan.execution_engine
            end
            # @return [Hash<String,CommandInterface>] the set of command subcommands
            #   attached to this command interface
            attr_reader :subcommands

            def initialize(app)
                @app = app
                @subcommands = {}
                refresh_subcommands
            end

            def refresh_subcommands
                self.class.each_subcommand do |name, (interface_model, description)|
                    unless subcommands[name]
                        subcommand(name, interface_model.new(app), description)
                    end
                end
            end

            # Declare a subcommand on this interface
            #
            # Unless with {CommandLibrary.subcommand}, the interface must
            # already be instanciated
            def subcommand(name, interface, description)
                subcommands[name] = [interface, description]
            end

            # Enumerate the subcommands available on this interface
            #
            # @yieldparam [String] name the subcommand name
            def each_subcommand
                return enum_for(__method__) unless block_given?

                refresh_subcommands
                subcommands.each do |name, (interface, description)|
                    yield(name, interface, description)
                end
            end

            InterfaceCommands = Struct.new :name, :description, :commands

            # The set of commands that exist on self and on its subcommands
            #
            # @return [Hash<String,InterfaceCommands>] the set of commands of
            #   self (with key '') and of its subcommands (where the key is not
            #   empty)
            def commands
                result = Hash["" => InterfaceCommands.new("", nil, self.class.commands)]
                each_subcommand do |name, interface, description|
                    result[name] = InterfaceCommands.new(
                        name, description, interface.commands
                    )
                end
                result
            end
        end
    end
end
