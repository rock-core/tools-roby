require 'roby/app/gen'
class ActionsGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        @model_type = "actions"
        super
        @class_name = [class_name.first, "Actions"] + class_name[1..-1]
    end
end

