require 'roby/app/gen'
class TaskGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        super
        @model_type = "tasks"
    end
end

