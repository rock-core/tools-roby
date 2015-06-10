module Roby
    module Models
        # Support for argument handling in the relevant models (task services
        # and tasks)
        module Arguments
            extend MetaRuby::Attributes

            # The set of knwon argument names
            #
            # @return [Set<Symbol>]
            inherited_attribute("argument_set", "argument_set") { ValueSet.new }

            # The set of known argument default values
            #
            # @return [Set<#evaluate_delayed_argument>]
            inherited_attribute("argument_default", "argument_defaults", map: true) { Hash.new }

            # @return [Boolean] returns if the given name is a known argument of
            #   this task
            def has_argument?(name)
                each_argument_set do |arg_name|
                    if arg_name == name
                        return true
                    end
                end
                nil
            end

            # @return [Array<String>] the list of arguments required by this task model
            def arguments
                return(@argument_enumerator ||= enum_for(:each_argument_set))
            end

            # @overload argument(argument_name, options)
            #   @param [String] argument_name the name of the new argument
            #   @param [Hash] options
            #   @option options default the default value for this argument. It
            #     can either be a plain value (e.g. a number) or one of the
            #     delayed arguments (see examples below)
            #
            # @example getting an argument at runtime from another object
            #   argument :target_point, :default => from(:planned_task).target_point
            # @example getting an argument at runtime from the global configuration
            #   argument :target_point, :default => from_conf.target_position
            # @example defining 'nil' as a default value
            #   argument :main_direction, :default => nil
            def argument(arg_name, **options)
                options = Kernel.validate_options options, default: nil

                arg_name = arg_name.to_sym
                argument_set << arg_name
                unless method_defined?(arg_name)
                    define_method(arg_name) { arguments[arg_name] }
                    define_method("#{arg_name}=") { |value| arguments[arg_name] = value }
                end

                if options.has_key?(:default)
                    defval = options[:default]
                    if !defval.respond_to?(:evaluate_delayed_argument)
                        argument_defaults[arg_name] = DefaultArgument.new(defval)
                    else
                        argument_defaults[arg_name] = defval
                    end
                end
            end

            # Access an argument's default value
            #
            # @param [String] argname the argument name
            # @return [(Boolean,Object)] the first returned value determines
            #   whether there is a default defined for the requested argument and
            #   the second is that value. Note that the default value can be nil.
            def default_argument(argname)
                each_argument_default(argname.to_sym) do |value|
                    return true, value
                end
                nil
            end

            # The part of +arguments+ that is meaningful for this task model
            def meaningful_arguments(arguments)
                self_arguments = self.arguments.to_set
                result = Hash.new
                arguments.each_assigned_argument do |key, value|
                    if self_arguments.include?(key)
                        result[key] = value
                    end
                end
                result
            end

            # Checks if this model fullfills everything in +models+
            def fullfills?(models)
                if !models.respond_to?(:each)
                    models = [models]
                end

                for tag in models
                    if !has_ancestor?(tag)
                        return false
                    end
                end
                true
            end
        end
    end
end


