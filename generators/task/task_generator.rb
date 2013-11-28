require 'roby/app/gen'
class TaskGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        @model_type = "tasks"
        super
    end
end

