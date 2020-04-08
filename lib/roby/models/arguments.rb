# frozen_string_literal: true

module Roby
    module Models
        # Support for argument handling in the relevant models (task services
        # and tasks)
        module Arguments
            extend MetaRuby::Attributes

            # Representation of one argument
            Argument = Struct.new :name, :default, :doc do
                # Tests whether this argument has a default
                def has_default?
                    default != NO_DEFAULT_ARGUMENT
                end

                # Tests whether this argument has a delayed argument as default
                def has_delayed_default?
                    has_default? && TaskArguments.delayed_argument?(default)
                end
            end

            # The set of knwon argument names
            #
            # @return [Set<Symbol>]
            inherited_attribute("argument", "__arguments", map: true) { {} }

            # @return [Array<String>] the list of arguments required by this task model
            def arguments
                each_argument.map { |name, _| name }
            end

            # The null object used in {#argument} to signify that there are no
            # default arguments
            #
            # nil cannot be used as 'nil' is a valid default as well
            NO_DEFAULT_ARGUMENT = Object.new
            def NO_DEFAULT_ARGUMENT.evaluate_delayed_argument
                raise NotImplementedError,
                      "trying to evaluate Roby::Models::Task::NO_DEFAULT_ARGUMENT "\
                      "which is an internal null object"
            end
            NO_DEFAULT_ARGUMENT.freeze

            # @overload argument(argument_name, options)
            #   @param [String] argument_name the name of the new argument
            #   @param [Hash] options
            #   @param default the default value for this argument. It
            #     can either be a plain value (e.g. a number) or one of the
            #     delayed arguments (see examples below)
            #   @param doc documentation string for the argument. If left
            #     to nil, the method will attempt to extract the argument's
            #     documentation block.
            #
            # @example getting an argument at runtime from another object
            #   argument :target_point, default: from(:planned_task).target_point
            # @example getting an argument at runtime from the global configuration
            #   argument :target_point, default: from_conf.target_position
            # @example defining 'nil' as a default value
            #   argument :main_direction, default: nil
            def argument(name, default: NO_DEFAULT_ARGUMENT, doc: nil)
                name = name.to_sym
                unless TaskArguments.delayed_argument?(default)
                    default = DefaultArgument.new(default)
                end
                doc ||= MetaRuby::DSLs.parse_documentation_block(/\.rb$/, "argument")
                __arguments[name] = Argument.new(name, default, doc)

                if name =~ /^\w+$/ && !method_defined?(name)
                    define_method(name) { arguments[name] }
                    define_method("#{name}=") { |value| arguments[name] = value }
                end
            end

            # Access an argument's default value
            #
            # @param [String] argname the argument name
            # @return [(Boolean,Object)] the first returned value determines
            #   whether there is a default defined for the requested argument and
            #   the second is that value. Note that the default value can be nil.
            def default_argument(argname)
                if (arg = find_argument(argname)) && arg.has_default?
                    [true, arg.default]
                end
            end

            # The part of +arguments+ that is meaningful for this task model
            def meaningful_arguments(arguments)
                self_arguments = self.arguments
                result = {}
                arguments.each_assigned_argument do |key, value|
                    if self_arguments.include?(key)
                        result[key] = value
                    end
                end
                result
            end

            # Checks if this model fullfills everything in +models+
            def fullfills?(models)
                unless models.respond_to?(:each)
                    models = [models]
                end

                for tag in models
                    unless has_ancestor?(tag)
                        return false
                    end
                end
                true
            end
        end
    end
end
