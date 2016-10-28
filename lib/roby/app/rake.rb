require 'roby'
require 'rake'
require 'rake/tasklib'

module Roby
    module App
        # Rake task definitions for the Roby apps 
        module Rake
            # Rake task to run the Roby tests
            #
            # To use, add the following to your Rakefile:
            #
            #     require 'roby/app/rake'
            #     Roby::App::Rake::TestTask.new
            #
            # It create a test task per robot configuration, named
            # "test:${robot_name}". It also creates a test:all task that runs all
            # tests in sequence. You can inspect these tasks with
            #
            #     rake --tasks
            #
            # and call them with e.g.
            #
            #     rake test:default
            #
            # The test:all task will fail only at the end of all tests, reporting
            # which configuration actually failed. To stop at the first failure,
            # pass a '0' as argument, e.g.
            #
            #    rake 'test:all[0]'
            #
            # To use, just create a TestTask in your Rakefile:
            #
            #    Roby::App::Rake::TestTask.new
            #
            # Modify the 'robot_names' array if you want to restrict the tests
            # to some configurations
            #
            # @example restrict the tests to run only under the
            #   'only_this_configuration' configuration
            #
            #       Roby::App::Rake::TestTask.new do |t|
            #         t.robot_names = ['only_this_configuration']
            #       end
            #
            # The namespace under which the tasks are created can also be
            # changed by passing a parameter to the task's constructor.
            #
            # @example create tasks under the roby_tests namespace instead of 'test'
            #
            #      Roby::App::Rake::TestCase.new('roby_tests')
            #
            class TestTask < ::Rake::TaskLib
                # The base test task name
                attr_reader :task_name

                # The app
                #
                # It defaults to Roby.app
                attr_accessor :app

                # The list of robot configurations on which we should run the tests
                #
                # Use 'default' for the default configuration. It defaults to all
                # the robots defined in config/robots/
                #
                # @return [Array<String,(String,String)>]
                attr_accessor :robot_names

                def initialize(task_name = 'test')
                    super()

                    @task_name = task_name
                    @app = Roby.app
                    @robot_names = discover_robot_names
                    define
                end

                class Failed < RuntimeError; end

                def define
                    each_robot do |robot_name, robot_type|
                        task_name = task_name_for_robot(robot_name, robot_type)

                        desc "run the tests for configuration #{robot_name}:#{robot_type}"
                        task task_name do
                            if !run_roby('test', '-r', "#{robot_name},#{robot_type}")
                                raise Failed.new("failed to run tests for #{robot_name}:#{robot_type}")
                            end
                        end
                    end

                    desc "run tests for all known robots"
                    task "#{task_name}:all", [:keep_going] do |t, args|
                        failures = Array.new
                        keep_going = args.fetch(:keep_going, '1') == '1'
                        each_robot do |robot_name, robot_type|
                            if !run_roby('test', '-r', "#{robot_name},#{robot_type}")
                                if keep_going
                                    failures << [robot_name, robot_type]
                                else
                                    raise Failed.new("failed to run tests for #{robot_name}:#{robot_type}")
                                end
                            end
                        end
                        if !failures.empty?
                            raise Failed.new("failed to run the following test(s): #{failures.map { |name, type| "#{name}:#{type}" }.join(", ")}")
                        end
                    end
                end

                def task_name_for_robot(robot_name, robot_type)
                    if robot_name == robot_type
                        "#{task_name}:#{robot_name}"
                    else
                        "#{task_name}:#{robot_name}-#{robot_type}" 
                    end
                end

                def run_roby(*args)
                    pid = spawn(Gem.ruby, File.expand_path(File.join('..', '..', '..', 'bin', 'roby'), __dir__),
                           *args)
                    begin
                        _, status = Process.waitpid2(pid)
                        status.success?
                    rescue Interrupt
                        Process.kill pid
                        Process.waitpid(pid)
                    end
                end

                # Enumerate the robots on which tests should be run
                def each_robot(&block)
                    robot_names.each(&block)
                end

                # @api private
                #
                # Discover which robots are available on the current app
                def discover_robot_names
                    if !app.app_dir
                        app.guess_app_dir
                    end
                    app.setup_robot_names_from_config_dir
                    app.robots.each.to_a
                end
            end
        end
    end
end
