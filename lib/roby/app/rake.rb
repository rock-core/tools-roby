# frozen_string_literal: true

require "roby"
require "rake"
require "rake/tasklib"
require "shellwords"

module Roby
    module App
        # Utility for Rakefile's in the generated apps
        #
        # = Tests
        #
        # {Rake::TestTask} generates a set of Rake tasks which run the tests.
        # One task is created per robot configuration in `config/robots/`, and
        # one "test" task is created that runs all the others. For instance,
        # adding
        #
        #   Roby::App::Rake::TestTask.new
        #
        # in an app that has `config/robots/default.rb` and
        # `config/robots/live.rb` will generate the `test:default`, `test:live`
        # and `test` tasks.
        #
        # See {Rake::TestTask} documentation for possible configuration.
        # Attributes can be modified in a block passed to `new`, e.g.:
        #
        #   Roby::App::Rake::TestTask.new do |t|
        #       t.robot_names.delete(%w[default default])
        #   end
        #
        # The tests will by default run the default minitest reporter. However,
        # if the JUNIT environment variable is set to 1, they will instead be
        # configured to generate a junit-compatible report. The report is named
        # after the robot configuration (e.g. `default:default.junit.xml`) and
        # placed in the report dir.
        #
        # The report dir is by default a `.test-results` folder at the root of
        # the app. It can be changed by setting the `REPORT_DIR` environment
        # variable.
        #
        # = Rubocop
        #
        # {Rake.define_rubocop} will configure a "rubocop" task. Its sibling,
        # {Rake.define_rubocop_if_enabled} will do so, but controlled by a
        # `RUBOCOP` environment variable:
        #
        #   - `RUBOCOP=1` will require that rubocop is present and define the
        #     task
        #   - `RUBOCOP=0` will never define the task
        #   - any other value (including not having the variable defined) will
        #     define the task only if rubocop is available.
        #
        # Note that the method only defines the task. If you mean to have it run
        # along with the tests, you must add it explicitely as a dependency
        #
        #   task "test" => "rubocop"
        #
        # When using {Rake.define_rubocop_if_enabled}, use the method's return
        # value to guard against the cases where the task is not defined, e.g.
        #
        #   task "test" => "rubocop" if Roby::App::Rake.define_rubocop_if_enabled
        #
        # The task uses rubocop's standard output formatter by default.
        # However, if the JUNIT environment variable is set to 1, it will
        # instead be configured to generate a junit-compatible report named
        # `rubocop.junit.xml` in the same report dir than the tests.
        #
        # The report dir is by default a `.test-results` folder at the root of
        # the app. It can be changed by setting the `REPORT_DIR` environment
        # variable.
        module Rake
            # Whether the {.define_rubocop_if_enabled} should fail if rubocop is
            # not available
            #
            # It is true if RUBOCOP is set to 1. If RUBOCOP is set to anything
            # else that is not 0, {.define_rubocop_if_enabled} will enable
            # rubocop only if it is available
            def self.require_rubocop?
                ENV["RUBOCOP"] == "1"
            end

            # Whether the tests should run RuboCop, as defined by the RUBOCOP
            # environment variable
            #
            # It is true by default, false if the RUBOCOP environment variable
            # is set to 0
            #
            # This affects {.define_rubocop_if_enabled}
            def self.use_rubocop?
                ENV["RUBOCOP"] != "0"
            end

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

            # Whether code coverage reports should be generated
            def self.coverage?
                ENV["ROBY_TEST_COVERAGE"] == "1"
            end

            def self.report_sync_mutex
                @report_sync_mutex ||= Mutex.new
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

                # The hash with extra configuration to be inserted into Conf
                # for the tests we are running
                #
                # @return [Hash<String, String>]
                attr_accessor :config

                # The list of files that should be tested.
                #
                # @return [Array<String>]
                attr_accessor :test_files

                # The directory where the tests will be auto-discovered
                #
                # @return [String]
                attr_accessor :base_dir

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

                # Sets whether the tests should be started with the --force-discovery flag
                attr_writer :force_discovery

                # Only run tests that are present in this bundle
                attr_writer :self_only

                # Whether the tests should be started with the --ui flag
                def ui?
                    @ui
                end

                # Whether the tests should be started with the --force-discovery flag
                def force_discovery?
                    @force_discovery
                end

                # Whether the tests should be started with the --self flag
                def self_only?
                    @self_only
                end

                # Whether the tests should be started with the --self flag
                def coverage?
                    @coverage
                end

                def initialize(task_name = "test", all_by_default: false)
                    super()

                    @task_name = task_name
                    @app = Roby.app
                    @all_by_default = all_by_default
                    @robot_names = discover_robot_names
                    @config = {}
                    @test_files = []
                    @excludes = []
                    @ui = false
                    @force_discovery = false
                    @self_only = false

                    @coverage = Rake.coverage?
                    @use_junit = Rake.use_junit?
                    @report_dir = Rake.report_dir

                    yield self if block_given?
                    define
                end

                class Failed < RuntimeError; end

                def define
                    test_args = %i[keep_going synchronize_output omit_tests_success]

                    each_robot do |robot_name, robot_type|
                        task_name = task_name_for_robot(robot_name, robot_type)

                        desc "run the tests for configuration #{robot_name}:#{robot_type}"
                        task task_name, test_args do |t, args|
                            synchronize_output =
                                args.fetch(:synchronize_output, "0") == "1"
                            omit_tests_success =
                                args.fetch(:omit_tests_success, "0") == "1"
                            result = run_roby_test(
                                "-r", "#{robot_name},#{robot_type}",
                                coverage_name: task_name,
                                report_name: "#{robot_name}:#{robot_type}",
                                synchronize_output: synchronize_output,
                                omit_success: omit_tests_success
                            )
                            unless result
                                raise Failed.new("failed to run tests for "\
                                                 "#{robot_name}:#{robot_type}"),
                                      "tests failed"
                            end
                        end
                    end

                    desc "run tests for all known robots"
                    task "#{task_name}:all-robots", test_args do |t, args|
                        failures = []
                        keep_going = args.fetch(:keep_going, "1") == "1"
                        synchronize_output = args.fetch(:synchronize_output, "0") == "1"
                        omit_tests_success = args.fetch(:omit_tests_success, "0") == "1"
                        each_robot do |robot_name, robot_type|
                            coverage_name = "#{task_name}:all-robots:"\
                                            "#{robot_name}-#{robot_type}"
                            success = run_roby_test(
                                "-r", "#{robot_name},#{robot_type}",
                                coverage_name: coverage_name,
                                report_name: "#{robot_name}:#{robot_type}",
                                synchronize_output: synchronize_output,
                                omit_success: omit_tests_success
                            )

                            unless success
                                failures << [robot_name, robot_type]
                                handle_test_failures(failures) unless keep_going
                            end
                        end

                        handle_test_failures(failures)
                    end

                    desc "run all tests"
                    task "#{task_name}:all", test_args do |t, args|
                        synchronize_output = args.fetch(:synchronize_output, "0") == "1"
                        omit_tests_success = args.fetch(:omit_tests_success, "0") == "1"
                        pp synchronize_output
                        pp omit_tests_success
                        unless run_roby_test(coverage_name: "all",
                                             synchronize_output: synchronize_output,
                                             omit_success: omit_tests_success)
                            raise Failed.new("failed to run tests"),
                                  "failed to run tests"
                        end
                    end

                    if all_by_default?
                        desc "run all tests"
                        task task_name, test_args => "#{task_name}:all"
                    else
                        desc "run all robot tests"
                        task task_name, test_args => "#{task_name}:all-robots"
                    end
                end

                def write_captured_output_sync(success, output, omit_tests_success)
                    Rake.report_sync_mutex.synchronize do
                        puts output unless omit_tests_success && success
                    end
                end

                def write_captured_output(
                    success, output, synchronize_output, omit_tests_success
                )
                    if synchronize_output
                        write_captured_output_sync(success, output, omit_tests_success)
                    else
                        puts output unless omit_tests_success && success
                    end
                end

                def handle_test_failures(failures)
                    return if failures.empty?

                    msg = failures
                          .map { |name, type| "#{name}:#{type}" }
                          .join(", ")
                    raise Failed.new("failed to run the following test(s): "\
                                     "#{msg}"), "failed ot run tests"
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

                def spawn_process_capturing_output(bin, *args)
                    stdout_r, stdout_w = IO.pipe
                    pid = spawn(Gem.ruby, bin, *args, out: stdout_w, err: stdout_w)
                    stdout_w.close
                    [pid, stdout_r]
                end

                def read_captured_output_from_pipe(pid, read_pipe)
                    output = []
                    begin
                        while (output_fragment = read_pipe.read(512))
                            output << output_fragment
                        end
                        output.join ""
                    rescue Interrupt
                        Process.kill "TERM", pid
                        Process.waitpid pid
                        return
                    end
                end

                def wait_process_with_captured_output(
                    pid, read_pipe, synchronize_output:, omit_success:
                )
                    output = read_captured_output_from_pipe(pid, read_pipe)
                    _, status = Process.waitpid2(pid)
                    success = status.success?
                    write_captured_output(
                        success, output, synchronize_output, omit_success
                    )
                    puts "#{task_name} tests succeeded.\n\n" if success
                    success
                end

                def spawn_process(bin, *args)
                    pid = spawn(Gem.ruby, bin, *args)
                    begin
                        _, status = Process.waitpid2(pid)
                        status.success?
                    rescue Interrupt
                        Process.kill "TERM", pid
                        Process.waitpid pid
                        return
                    end
                end

                def run_roby_test(*args, report_name: "report", coverage_name: "roby",
                    synchronize_output: false, omit_success: false)
                    args += excludes.flat_map do |pattern|
                        ["--exclude", pattern]
                    end
                    args += config.flat_map do |k, v|
                        ["--set", "#{k}=#{v}"]
                    end
                    args += ["--base-dir", base_dir] if base_dir

                    args << "--ui" if ui?
                    args << "--force-discovery" if force_discovery?
                    args << "--self" if self_only?
                    args << "--coverage=#{coverage_name}" if coverage?
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

                    args += test_files.map(&:to_s)

                    puts "Running roby test #{args.join(' ')}"
                    run_roby("test", *args, synchronize_output: synchronize_output,
                                            omit_success: omit_success)
                end

                def run_roby(*args, synchronize_output: false, omit_success: false)
                    roby_bin = File.expand_path(
                        File.join("..", "..", "..", "bin", "roby"),
                        __dir__
                    )
                    kw_args = { err: :out }
                    capture_output = synchronize_output || omit_success
                    if capture_output
                        pid, read_pipe = spawn_process_capturing_output(roby_bin, *args)
                        wait_process_with_captured_output(
                            pid, read_pipe,
                            synchronize_output: synchronize_output,
                            omit_success: omit_success
                        )
                    else
                        spawn_process(roby_bin, *args)
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
            class RobotTestTask < ::Rake::TaskLib
                # The base test task name
                attr_reader :task_name

                # The app
                #
                # It defaults to Roby.app
                attr_accessor :app

                attr_accessor :robot_name, :robot_type

                # The hash with extra configuration to be inserted into Conf
                # for the tests we are running
                #
                # @return [Hash<String, String>]
                attr_accessor :config

                # The list of files that should be tested.
                #
                # @return [Array<String>]
                attr_accessor :test_files

                # The directory where the tests will be auto-discovered
                #
                # @return [String]
                attr_accessor :base_dir

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

                # Sets whether the tests should be started with the --force-discovery flag
                attr_writer :force_discovery

                # Only run tests that are present in this bundle
                attr_writer :self_only

                # Whether the tests should be started with the --ui flag
                def ui?
                    @ui
                end

                # Whether the tests should be started with the --force-discovery flag
                def force_discovery?
                    @force_discovery
                end

                # Whether the tests should be started with the --self flag
                def self_only?
                    @self_only
                end

                # Whether the tests should be started with the --self flag
                def coverage?
                    @coverage
                end

                def initialize(task_name = "test", robot_name:, robot_type: nil)
                    super()

                    @task_name = task_name
                    @app = Roby.app
                    @robot_name = robot_name
                    @robot_type = robot_type || robot_name
                    @config = {}
                    @test_files = []
                    @excludes = []
                    @ui = false
                    @force_discovery = false
                    @self_only = false

                    @coverage = Rake.coverage?
                    @use_junit = Rake.use_junit?
                    @report_dir = Rake.report_dir

                    yield self if block_given?
                    define
                end

                class Failed < RuntimeError; end

                def define
                    desc "run the tests for configuration #{robot_name}:#{robot_type}"
                    task task_name do
                        result = run_roby_test(
                            "-r", "#{robot_name},#{robot_type}",
                            coverage_name: task_name,
                            report_name: "#{robot_name}:#{robot_type}"
                        )
                        unless result
                            raise Failed.new("failed to run tests for "\
                                             "#{robot_name}:#{robot_type}"),
                                  "tests failed"
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

                # Whether the tests should generate a JUnit report in {#report_dir}
                def use_junit?
                    @use_junit
                end

                # Path to the JUnit/Rubocop reports (if enabled)
                attr_accessor :report_dir

                def run_roby_test(*args, report_name: "report", coverage_name: "roby")
                    args += excludes.flat_map do |pattern|
                        ["--exclude", pattern]
                    end
                    args += config.flat_map do |k, v|
                        ["--set", "#{k}=#{v}"]
                    end
                    args += ["--base-dir", base_dir] if base_dir

                    args << "--ui" if ui?
                    args << "--force-discovery" if force_discovery?
                    args << "--self" if self_only?
                    args << "--coverage=#{coverage_name}" if coverage?
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

                    args += test_files.map(&:to_s)

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
            end

            def self.define_rubocop_if_enabled(
                junit: Rake.use_junit?, report_dir: Rake.report_dir,
                required: Rake.require_rubocop?
            )
                return false unless Rake.use_rubocop?

                begin
                    require "rubocop/rake_task"
                rescue LoadError
                    raise if required

                    return
                end

                define_rubocop(junit: junit, report_dir: report_dir)
                true
            end

            def self.define_rubocop(
                junit: Rake.use_junit?, report_dir: Rake.report_dir
            )
                require "rubocop/rake_task"
                RuboCop::RakeTask.new do |t|
                    if junit
                        t.formatters << "junit"
                        t.options << "-o" << "#{report_dir}/rubocop.junit.xml"
                    end
                end
            end
        end
    end
end
