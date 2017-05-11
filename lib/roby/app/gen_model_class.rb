module Roby
    module App
        class GenModelClass < GenBase
            # Converts an input string that is in camelcase into a path string
            #
            # NOTE: Facets' String#pathize and String#snakecase have corner
            # cases that really don't work for us:
            #   '2D'.snakecase => '2_d'
            #   'GPS'.pathize => 'gp_s'
            #
            def self.pathize(string)
                string.
                    gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
                    gsub(/([a-z])([A-Z][a-z])/,'\1_\2').
                    gsub('__','/').
                    gsub('::','/').
                    gsub(/\s+/, '').                # spaces are bad form
                    gsub(/[?%*:|"<>.]+/, '').   # reserved characters
                    downcase
            end

            attr_reader :class_name
            attr_reader :file_name
            attr_reader :model_type

            def initialize(runtime_args, runtime_options = Hash.new)
                super

                target_path  = args.shift
                given_name   = target_path.gsub(/\.rb$/, '')

                robot_module =
                    if robot_name
                        [robot_name.camelcase(:upper)]
                    else
                        []
                    end

                @class_name = Roby.app.module_name.split("::") +
                    Array(model_type).map { |t| t.camelcase(:upper) } +
                    robot_module +
                    given_name.camelcase(:upper).split("::")

                @file_name = *class_name[1..-1].map do |camel|
                    GenModelClass.pathize(camel)
                end
            end

            def manifest
                record do |m|
                    subdir     = File.join(*file_name[0..-2])
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

                    m.template 'class.rb', "#{require_path}.rb", assigns: local_vars
                    if has_test? || force_tests?
                        m.directory "test/#{subdir}"
                        m.template 'test.rb', "#{test_require_path}.rb", assigns: local_vars
                    end
                end
            end
            
            def has_test?; true end
        end
    end
end
