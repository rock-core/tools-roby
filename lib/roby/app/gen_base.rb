require 'rubigen'
module Roby
    module App
        class GenBase < RubiGen::Base
            module RecorderExtension
                def directory(relative_destination)
                    super(target.resolve_robot_in_path(relative_destination))
                end
                def file(relative_source, relative_destination, file_options = Hash.new, &block)
                    relative_destination = target.resolve_robot_in_path(relative_destination)
                    super(relative_source, relative_destination, file_options, &block)
                end
                def template(template, dest, *args, &block)
                    super(template, target.resolve_robot_in_path(dest), *args, &block)
                end
            end

            # @return [String] the name of the robot that should be used to
            #   resolve the ROBOT placeholder
            attr_reader :robot_name

            # @return [Boolean] whether the generator should generate tests
            #   even if they are disabled by default
            attr_predicate :force_tests?, true

            def initialize(runtime_args, runtime_options = Hash.new)
                self.force_tests = false

                super
                usage if args.empty?

                Roby.app.require_app_dir
                @destination_root = Roby.app.app_dir
            end

            def resolve_robot_in_path(path)
                App.resolve_robot_in_path(path, robot_name)
            end

            def record
                super() do |m|
                    m.extend RecorderExtension
                    yield(m)
                end
            end

            # Helper to update files whose main purpose is to require other
            # files in the folder hierarchy.
            #
            # @param [RubiGen::Manifest] manifest the manifest we use to
            #   create/update files
            # @param [String] relative_source the path to the template used to
            #   require the sub-files. The file path is available in the
            #   required_file local variable in the template
            # @param [String] file the path to the file that should be
            #   created/updated
            # @param [String] base_path the path under which we should not
            #   update/create any file anymore
            # @param [String] file_patterns the pattern used to create the
            #   aggregate file. Use %s as placeholder for basename
            #
            # @example create/update suite_XXX.rb files to require the tests under subdirectories
            #   # Creates test/suite_in.rb test/in/suite_a.rb test/in/a/suite_dir.rb
            #   register_in_aggregate_require_files(m, "require_file.rb", "test/in/a/dir/test_file.rb", "test", "suite_%.rb"
            #
            def register_in_aggregate_require_files(manifest, relative_source, file, base_path, file_pattern)
                file = resolve_robot_in_path(file)
                base_path = resolve_robot_in_path(base_path)
                base_path = base_path.gsub(/\/$/, '')
                path = File.dirname(file)
                while path != base_path
                    new_basename = file_pattern % [File.basename(path, ".rb")]
                    new_path = File.dirname(path)
                    new_file = File.join(new_path, new_basename)
                    required_file = File.join(File.dirname(file), File.basename(file, '.rb'))
                    manifest.add_template_to_file(relative_source, new_file, :assigns => Hash['required_file' => required_file])
                    file = new_file
                    path = File.dirname(path)
                    if path.empty? || path == "."
                        raise ArgumentError, "#{base_path} is not a parent path for #{file}"
                    end
                end
            end

            # Helper to handle opening and closing modules
            #
            # @return [(String,String,String)] the indentation string for the
            #   module's content, the code necessary to open the module and the
            #   code to close it
            #
            # @example usually used in e.g. ERB with
            #   <% indent, open, close = Roby::App::GenBase.in_module("A", "Module") %>
            #   <%= open %>
            #   <%= indent %>class MyClass
            #   <%= indent %>    it_does_something
            #   <%= indent %>end
            #   <%= close %>
            #
            def self.in_module(*module_path)
                indent = ""
                open_code  = []
                close_code = []
                module_path.each do |m|
                    open_code.push "#{indent}module #{m}"
                    close_code.unshift "#{indent}end"
                    indent = indent + "    "
                end
                return indent, open_code.join("\n"), close_code.join("\n")
            end

            # Overloaded to add the -r option to the command line
            #
            # This is called by rubigen on option parsing
            def add_options!(opt)
                opt.on '--with-tests', 'for generators that do not generate tests by default, force adding a test file' do
                    @force_tests = true
                end
                opt.on '-r NAME', '--robot NAME' do |name|
                    @robot_name = name
                end
            end

            # Overloaded to add a proper banner
            def banner
                "Usage: roby gen #{spec.name} NAME [options]"
            end
        end
    end
end
