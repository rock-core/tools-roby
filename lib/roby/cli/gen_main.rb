require 'roby/cli/gen/helpers'
require 'thor'

module Roby
    module CLI
        class GenMain < Thor
            include Thor::Actions


            namespace :gen
            source_paths << File.join(__dir__, 'gen')

            desc "app [DIR]", "creates a new app scaffold in the current directory, or DIR if given"
            option :quiet, type: :boolean, default: false
            def app(dir = nil, init_path: 'roby_app', robot_path: 'roby_app')
                if dir
                    if File.exist?(dir)
                        raise CLIInvalidArguments, "#{dir} already exists"
                    end
                else
                    dir = Dir.pwd
                end

                directory 'app/', dir, verbose: !options[:quiet]
                copy_file File.join(init_path, 'config' , 'init.rb'), File.join(dir, 'config', 'init.rb'), verbose: !options[:quiet]
                template File.join(robot_path, 'config', "robots", "robot.rb"),
                    File.join(dir, "config", "robots", "default.rb"),
                    context: Gen.make_context('robot_name' => 'default'),
                    verbose: !options[:quiet]
                dir
            end

            desc "robot ROBOT_NAME", "creates a new robot configuration"
            def robot(name, robot_path: 'roby_app')
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                template File.join(robot_path, 'config', "robots", "robot.rb"),
                    File.join("config", "robots", "#{name}.rb"),
                    context: Gen.make_context('robot_name' => name)
            end

            desc "action ACTION_FILE_OR_CLASS", "create a new action interface at the provided file"
            option :robot, aliases: 'r', desc: 'the robot name for robot-specific scaffolding',
                type: :string, default: nil
            def actions(name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                file_name, class_name = Gen.resolve_name(
                    'actions', name, options[:robot], ['models', 'actions'], ["Actions"])

                template File.join('actions', 'class.rb'),
                    File.join('models', 'actions', *file_name) + ".rb",
                    context: Gen.make_context('class_name' => class_name)
                template File.join('actions', "test.rb"),
                    File.join('test', 'actions', *file_name[0..-2], "test_#{file_name[-1]}.rb"),
                    context: Gen.make_context(
                        'class_name' => class_name,
                        'require_path' => File.join('models', "actions", *file_name))
            end

            desc "class CLASS_NAME", "creates a new utility class in lib/"
            def klass(name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                file_name, class_name = Gen.resolve_name(
                    'class', name, nil, ['lib', Roby.app.app_name], [])

                template File.join('class', 'class.rb'),
                    File.join('lib', Roby.app.app_name, *file_name) + ".rb",
                    context: Gen.make_context('class_name' => class_name)
                template File.join('class', "test.rb"),
                    File.join('test', 'lib', *file_name[0..-2], "test_#{file_name[-1]}.rb"),
                    context: Gen.make_context(
                        'class_name' => class_name,
                        'require_path' => File.join(Roby.app.app_name, *file_name))
            end

            desc "module MODULE_NAME", "creates a new utility module in lib/"
            def module(name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                file_name, class_name = Gen.resolve_name(
                    'module', name, nil, ['lib', Roby.app.app_name], [])

                template File.join('module', 'module.rb'),
                    File.join('lib', Roby.app.app_name, *file_name) + ".rb",
                    context: Gen.make_context('module_name' => class_name)
                template File.join('module', "test.rb"),
                    File.join('test', 'lib', *file_name[0..-2], "test_#{file_name[-1]}.rb"),
                    context: Gen.make_context(
                        'module_name' => class_name,
                        'require_path' => File.join(Roby.app.app_name, *file_name))
            end

            desc "task NAME", "creates a new Roby task model"
            option :robot, aliases: 'r', desc: 'the robot name for robot-specific scaffolding',
                type: :string, default: nil
            def task(name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                file_name, class_name = Gen.resolve_name(
                    'tasks', name, options[:robot], ['models', 'tasks'], ["Tasks"])

                template File.join('task', 'class.rb'),
                    File.join('models', 'tasks', *file_name) + ".rb",
                    context: Gen.make_context('class_name' => class_name)
                template File.join('task', "test.rb"),
                    File.join('test', 'tasks', *file_name[0..-2], "test_#{file_name[-1]}.rb"),
                    context: Gen.make_context(
                        'class_name' => class_name,
                        'require_path' => File.join('models', "tasks", *file_name))
            end
        end
    end
end
