require 'roby/app/gen_base'
class TaskGenerator < Roby::App::GenBase
    # @return [Array<String>] path to the class
    attr_reader :class_name
    attr_reader :file_name

    def initialize(runtime_args, runtime_options = Hash.new)
        super
        usage if args.empty?

        Roby.app.require_app_dir
        @destination_root = Roby.app.app_dir

        given_name = args.shift
        @class_name = Roby.app.app_name.camelize.split("::") +
            given_name.camelize.split("::")
        @file_name = *class_name[1..-1].map(&:snakecase)
    end

    def manifest
        record do |m|
            subdir     = "ROBOT/tasks/#{File.join(*file_name[0..-2])}"
            basename = file_name[-1]
            m.directory "models/#{subdir}"
            m.directory "test/#{subdir}"

            local_vars = Hash[
                'file_name' => file_name,
                'class_name' => class_name,
                'subdir' => subdir,
                'basename' => basename]
            m.template 'task.rb', "models/#{subdir}/#{basename}.rb", :assigns => local_vars
            m.template 'test_task.rb', "test/#{subdir}/test_#{basename}.rb", :assigns => local_vars
        end
    end
end

