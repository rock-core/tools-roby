require 'roby/app/gen'
class ActionsGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        @model_type = "actions"
        super
    end
end

