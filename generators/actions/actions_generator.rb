require 'roby/app/gen'
class ActionsGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        super
        @model_type = "actions"
        @class_name = [class_name.first, "Actions"] + class_name[1..-1]
    end
end

