require 'roby/app/gen'
class RobotGenerator < Roby::App::GenBase
    attr_reader :robot_name

    def initialize(runtime_args, runtime_options = Hash.new)
        super
        @robot_name = File.basename(args.shift, '.rb')
    end

    def manifest
        record do |m|
            m.directory "config/robots"
            m.template 'robot.rb', "config/robots/#{robot_name}.rb"
        end
    end
end

