require 'facets/string/pathize'
module Roby
    module App
        class GenModelClass < GenBase
            attr_reader :class_name
            attr_reader :file_name
            attr_reader :model_type

            def initialize(runtime_args, runtime_options = Hash.new)
                super

                target_path = args.shift
                given_name = target_path.gsub(/\.rb$/, '')
                @class_name = Roby.app.module_name.split("::") +
                    given_name.camelcase(:upper).split("::")
                @file_name = *class_name[1..-1].map(&:pathize)
            end

            def manifest
                record do |m|
                    subdir     = "ROBOT/#{model_type}/#{File.join(*file_name[0..-2])}"
                    basename = file_name[-1]
                    m.directory "models/#{subdir}"
                    require_path = "models/#{subdir}/#{basename}"
                    test_require_path = "test/#{subdir}/test_#{basename}"

                    local_vars = Hash[
                        'file_name' => file_name,
                        'class_name' => class_name,
                        'subdir' => subdir,
                        'basename' => basename,
                        'require_path' => require_path]

                    m.template 'class.rb', "#{require_path}.rb", :assigns => local_vars
                    register_in_aggregate_require_files(m, "require_file.rb", "#{require_path}.rb", "models/ROBOT/#{model_type}", "%s.rb")
                    if has_test?
                        m.directory "test/#{subdir}"
                        m.template 'test.rb', "#{test_require_path}.rb", :assigns => local_vars
                        register_in_aggregate_require_files(m, "require_file.rb", "#{test_require_path}.rb", "test/ROBOT", "suite_%s.rb")
                    end
                end
            end
            
            def has_test?; true end
        end
    end
end
