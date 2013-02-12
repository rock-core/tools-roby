module Roby
    module Models
        # Support for argument handling in the relevant models (task services
        # and tasks)
        module Arguments
            extend MetaRuby::Attributes
            inherited_attribute("argument_set", "argument_set") { ValueSet.new }
            inherited_attribute("argument_default", "argument_defaults", :map => true) { Hash.new }

            def has_argument?(name)
                each_argument_set do |arg_name|
                    if arg_name == name
                        return true
                    end
                end
                nil
            end

            # Returns the list of static arguments required by this task model
            def arguments(*new_arguments)
                if new_arguments.empty?
                    return(@argument_enumerator ||= enum_for(:each_argument_set))
                end

                Roby.warn_deprecated "Roby::Task.arguments(:arg1, :arg2) is deprecated. Use argument(:arg1); argument(:arg2) instead.", 2
                new_arguments.each do |arg_name|
                    argument(arg_name)
                end
            end

            # Declare one argument
            def argument(*new_arguments)
                if new_arguments.last.kind_of?(Hash)
                    options = new_arguments.pop
                end
                if (new_arguments.size == 2 && !options) || new_arguments.size > 2
                    Roby.warn_deprecated "Roby::Task.argument(:arg1, :arg2) is deprecated. Use argument(:arg1); argument(:arg2) instead."
                end

                options = Kernel.validate_options(options || Hash.new, :default => nil)

                new_arguments.each do |arg_name|
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
            end

            # Returns whether there is a default value for this argument, and
            # the actual default value
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
                arguments.values.each do |key, value|
                    if self_arguments.include?(key) && !value.respond_to?(:evaluate_delayed_argument)
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


