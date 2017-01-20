module Roby
    module Coordination
        module Models
            # Placeholder, in the execution contexts, for variables. It is
            # used for instance to hold the arguments to the state machine during
            # modelling, replaced by their values during instanciation
            Variable = Struct.new :name do
                include Tools::Calculus::Build
                def evaluate(variables)
                    if variables.has_key?(name)
                        variables[name]
                    else
                        raise ArgumentError, "expected a value for #{arg}, got none"
                    end
                end

                def to_s
                    "var:#{name}"
                end

                def to_coordination_task(task_model = Roby::Task)
                    TaskFromVariable.new(name, task_model)
                end

                def evaluate_delayed_argument(task)
                    throw :no_value
                end
            end
        end
    end
end

