require 'roby/app/gen'
class ModuleGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        runtime_args = runtime_args.map do |arg|
            if arg =~ /^(\w+)\//
                @model_type = $1
                $'
            elsif arg =~ /^(\w+)::/
                @model_type = $1.downcase
                $'
            end
        end

        super(runtime_args, runtime_options)
    end
end

