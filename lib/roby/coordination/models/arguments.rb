# frozen_string_literal: true

module Roby
    module Coordination
        module Models
            module Arguments
                extend MetaRuby::Attributes

                Argument = Struct.new :name, :required, :default

                # The set of arguments available to this execution context
                # @return [Array<Symbol>]
                inherited_attribute(:argument, :arguments, map: true) { {} }

                # Define a new argument for this coordination model
                #
                # Arguments are made available within the coordination model as
                # Variable objects
                #
                # @param [String,Symbol] name the argument name
                # @param [Hash] options
                # @option options :default a default value for this argument. Note
                #   that 'nil' is considered as a proper default value.
                # @return [Argument] the new argument object
                def argument(name, options = {})
                    options = Kernel.validate_options options, :default
                    arguments[name.to_sym] = Argument.new(name.to_sym, !options.has_key?(:default), options[:default])
                end

                # Validates that the provided argument hash is valid for this
                # particular coordination model
                #
                # @raise ArgumentError if some given arguments are not known to this
                #   model, or if some required arguments are not set
                def validate_arguments(arguments)
                    arguments = Kernel.normalize_options arguments
                    arguments.each_key do |arg_name|
                        unless find_argument(arg_name)
                            raise ArgumentError,
                                  "#{arg_name} is not an argument on #{self}"
                        end
                    end

                    each_argument do |_, arg|
                        next if arguments.has_key?(arg.name)

                        if arg.required
                            raise ArgumentError,
                                  "#{arg.name} is required by #{self}, but is "\
                                  "not provided (given arguments: #{arguments})"
                        end

                        arguments[arg.name] = arg.default
                    end
                    arguments
                end
            end
        end
    end
end
