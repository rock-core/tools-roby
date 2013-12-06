module Roby
    module App
        class GenModelClass < GenBase
            attr_reader :class_name
            attr_reader :file_name
            attr_reader :model_type

            def initialize(runtime_args, runtime_options = Hash.new)
                super

                target_path = args.shift
                if target_path !~ /^models\/#{model_type}\//
                    raise ArgumentError, "was expecting a prefix of models/#{model_type} for the #{model_type} generator"
                end
                given_name = $'.gsub(/\.rb$/, '')
                @class_name = Roby.app.app_name.camelize.split("::") +
                    given_name.camelize.split("::")
                @file_name = *class_name[1..-1].map(&:snakecase)
            end

            def manifest
                record do |m|
                    subdir     = "ROBOT/#{model_type}/#{File.join(*file_name[0..-2])}"
                    basename = file_name[-1]
                    m.directory "models/#{subdir}"
                    m.directory "test/#{subdir}"

                    local_vars = Hash[
                        'file_name' => file_name,
                        'class_name' => class_name,
                        'subdir' => subdir,
                        'basename' => basename]
                    m.template 'class.rb', "models/#{subdir}/#{basename}.rb", :assigns => local_vars
                    m.template 'test.rb', "test/#{subdir}/test_#{basename}.rb", :assigns => local_vars
                end
            end
        end
    end
end
