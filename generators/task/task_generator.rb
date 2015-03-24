require 'roby/app/gen'
class TaskGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        @model_type = "tasks"
        super
        @class_name = [class_name.first, "Tasks"] + class_name[1..-1]
    end
end

