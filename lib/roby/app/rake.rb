# frozen_string_literal: true

require "roby"
require "rake"
require "rake/tasklib"
require "shellwords"

module Roby
    module App
        # Rake task definitions for the Roby apps
        module Rake
            # Whether the tests and rubocop should generate a JUnit report
            #
            # This is false by default, true if the JUNIT environment variable
            # is set to 1
            def self.use_junit?
                ENV["JUNIT"] == "1"
            end

            # The reporting dir when generating JUnit reports
            #
            # Defaults to the current dir `.test-results` subdirectory. Can be
            # overriden with the REPORT_DIR environment variable
            def self.report_dir
                ENV["REPORT_DIR"] || File.expand_path(".test-results")
            end

            # Rake task to run the Roby tests
            #
            # To use, add the following to your Rakefile:
            #
            #     require 'roby/app/rake'
            #     Roby::App::Rake::TestTask.new
            #
            # It create a test task per robot configuration, named
            # "test:${robot_name}". It also creates a test:all-robots task that
            # runs each robot's configuration in sequence. You can inspect these
            # tasks with
            #
            #     rake --tasks
            #
            # and call them with e.g.
            #
            #     rake test:default
            #
            # The test:all-robots task will fail only at the end of all tests, reporting
            # which configuration actually failed. To stop at the first failure,
            # pass a '0' as argument, e.g.
            #
            #    rake 'test:all-robots[0]'
            #
            # Finally, the 'test:all' target runs syskit test --all (i.e. runs
            # all tests in the default robot configuration)
            #
            # The 'test' target points by default to test:all-robots. See below
            # to change this.
            #
            # The following examples show how to fine-tune the creates tests:
            #
            # @example restrict the tests to run only under the
            #   'only_this_configuration' configuration
            #
            #      Roby::App::Rake::TestTask.new do |t|
            #          t.robot_names = ['only_this_configuration']
            #      end
            #
            # @example create tasks under the roby_tests namespace instead of 'test'
            #
            #      Roby::App::Rake::TestCase.new('roby_tests')
            #
            # @example make 'test' point to 'test:all'
            #
            #      Roby::App::Rake::TestCase.new do |t|
            #          t.all_by_default = true
            #      end
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

                # Patterns matching excluded test files
                #
                # It accepts any string that File.fnmatch? accepts
                #
                # @return [Array<String>]
                attr_accessor :excludes

                # Whether the 'test' target should run all robot tests (false, the
                # default) or the 'all tests' target (true)
                attr_predicate :all_by_default?, true

                # Sets whether the tests should be started with the --ui flag
                attr_writer :ui

                # Whether the tests should be started with the --ui flag
                def ui?
                    @ui
                end

                def initialize(task_name = "test", all_by_default: false)
                    @task_name = task_name
                    @app = Roby.app
                    @all_by_default = all_by_default
                    @robot_names = discover_robot_names
                    @excludes = []
                    @ui = false

                    @use_junit = Rake.use_junit?
                    @report_dir = Rake.report_dir

                    yield self if block_given?
                    define
                end

                class Failed < RuntimeError; end

                def define
                    each_robot do |robot_name, robot_type|
                        task_name = task_name_for_robot(robot_name, robot_type)

                        desc "run the tests for configuration #{robot_name}:#{robot_type}"
                        task task_name do
                            result = run_roby_test(
                                "-r", "#{robot_name},#{robot_type}",
                                report_name: "#{robot_name}:#{robot_type}"
                            )
                            unless result
                                raise Failed.new("failed to run tests for "\
                                                 "#{robot_name}:#{robot_type}"),
                                      "tests failed"
                            end
                        end
                    end

                    desc "run tests for all known robots"
                    task "#{task_name}:all-robots", [:keep_going] do |t, args|
                        failures = []
                        keep_going = args.fetch(:keep_going, "1") == "1"
                        each_robot do |robot_name, robot_type|
                            result = run_roby_test(
                                "-r", "#{robot_name},#{robot_type}",
                                report_name: "#{robot_name}:#{robot_type}"
                            )
                            unless result
                                if keep_going
                                    failures << [robot_name, robot_type]
                                else
                                    raise Failed.new("failed to run tests for "\
                                                     "#{robot_name}:#{robot_type}"),
                                          "tests failed"
                                end
                            end
                        end
                        unless failures.empty?
                            msg = failures
                                  .map { |name, type| "#{name}:#{type}" }
                                  .join(", ")
                            raise Failed.new("failed to run the following test(s): "\
                                             "#{msg}"), "failed ot run tests"
                        end
                    end

                    desc "run all tests"
                    task "#{task_name}:all" do
                        unless run_roby_test
                            raise Failed.new("failed to run tests"),
                                  "failed to run tests"
                        end
                    end

                    if all_by_default?
                        desc "run all tests"
                        task task_name => "#{task_name}:all"
                    else
                        desc "run all robot tests"
                        task task_name => "#{task_name}:all-robots"
                    end
                end

                def task_name_for_robot(robot_name, robot_type)
                    if robot_name == robot_type
                        "#{task_name}:#{robot_name}"
                    else
                        "#{task_name}:#{robot_name}-#{robot_type}"
                    end
                end

                # Whether the tests should generate a JUnit report in {#report_dir}
                def use_junit?
                    @use_junit
                end

                # Path to the JUnit/Rubocop reports (if enabled)
                attr_accessor :report_dir

                def run_roby_test(*args, report_name: "report")
                    args += excludes.flat_map do |pattern|
                        ["--exclude", pattern]
                    end
                    args << "--ui" if ui?
                    args << "--"
                    if (minitest_opts = ENV["TESTOPTS"])
                        args.concat(Shellwords.split(minitest_opts))
                    end

                    if use_junit?
                        args += [
                            "--junit", "--junit-jenkins",
                            "--junit-filename=#{report_dir}/#{report_name}.junit.xml"
                        ]
                        FileUtils.mkdir_p report_dir
                    end

                    puts "Running roby test #{args.join(' ')}"
                    run_roby("test", *args)
                end

                def run_roby(*args)
                    roby_bin = File.expand_path(
                        File.join("..", "..", "..", "bin", "roby"),
                        __dir__
                    )
                    pid = spawn(Gem.ruby, roby_bin, *args)
                    begin
                        _, status = Process.waitpid2(pid)
                        status.success?
                    rescue Interrupt
                        Process.kill "TERM", pid
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
                    app.guess_app_dir unless app.app_dir
                    app.setup_robot_names_from_config_dir
                    app.robots.each.to_a
                end
            end
        end
    end
end
