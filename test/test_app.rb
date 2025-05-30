# frozen_string_literal: true

require "roby/test/self"
require "roby/test/roby_app_helpers"
require "roby/droby/logfile/writer"
require "roby/droby/logfile/client"
require "roby/cli/gen_main"

module Roby
    class LoggerContext
        class LoggerMock
            attr_accessor :formatter

            def initialize(formatter)
                @formatter = formatter
            end
        end

        attr_accessor :logger

        def initialize(formatter)
            @logger = LoggerMock.new(formatter)
        end
    end

    describe Application do
        include Test::RobyAppHelpers

        describe "filesystem access and resolution" do
            before do
                app.search_path = [app_dir]
            end

            describe "#app_dir" do
                before do
                    @app = Roby::Application.new
                    @root = make_tmpdir
                end

                it "returns the current app_dir if set" do
                    app.app_dir = @root
                    assert_equal @root, app.app_dir
                end

                it "lets the caller reset the app dir" do
                    app.app_dir = @root
                    assert_equal @root, app.app_dir
                    app.app_dir = nil
                    assert_nil app.app_dir
                end
            end

            describe "#app_path" do
                before do
                    @app = Roby::Application.new
                    @root = make_tmpdir
                end

                it "returns nil if the app dir is not set" do
                    assert_nil @app.app_path
                end

                it "returns the value of app_dir converted to a pathname" do
                    @app.app_dir = @root
                    assert_equal Pathname(@root), @app.app_path
                end

                it "returns nil if the app_dir has been reset" do
                    @app.app_dir = @root
                    assert_equal Pathname(@root), @app.app_path
                    @app.app_dir = nil
                    assert_nil @app.app_path
                end

                it "returns the new value of app_dir if it has been changed" do
                    @app.app_dir = @root
                    assert_equal Pathname(@root), @app.app_path
                    @app.app_dir = new_root = make_tmpdir
                    assert_equal Pathname(new_root), @app.app_path
                end
            end

            describe ".guess_app_dir" do
                after do
                    ENV.delete("ROBY_APP_DIR")
                end
                it "resolves the ROBY_APP_DIR environment variable if given" do
                    gen_app
                    ENV["ROBY_APP_DIR"] = app_dir
                    assert_equal app_dir, Application.guess_app_dir
                end
                it "raises if ROBY_APP_DIR points to a directory that is not a valid Roby app" do
                    ENV["ROBY_APP_DIR"] = app_dir
                    assert_raises(Application::InvalidRobyAppDirEnv) do
                        Application.guess_app_dir
                    end
                end
                it "returns Dir.pwd if it is the root of a Roby application" do
                    gen_app
                    FlexMock.use(Dir) do |mock|
                        mock.should_receive(:pwd).and_return(app_dir)
                        assert_equal app_dir, Application.guess_app_dir
                    end
                end
                it "looks for a roby application starting at the current working directory" do
                    gen_app
                    FileUtils.mkdir_p(path = File.join(app_dir, "test", "path", "in", "app"))
                    FlexMock.use(Dir) do |mock|
                        mock.should_receive(:pwd).and_return(path)
                        assert_equal app_dir, Application.guess_app_dir
                    end
                end
                it "returns nil if Dir.pwd is not within a valid application " do
                    FileUtils.mkdir_p(path = File.join(app_dir, "test", "path", "in", "app"))
                    FlexMock.use(Dir) do |mock|
                        mock.should_receive(:pwd).and_return(path)
                        assert_nil Application.guess_app_dir
                    end
                end
            end

            describe "#make_path_relative" do
                it "keeps absolute paths that are not in the search path as-is" do
                    absolute_path = "/not/in/search/path"
                    assert_equal(absolute_path, app.make_path_relative(absolute_path))
                end

                it "keeps absolute paths that are not present on disk as-is" do
                    absolute_path = "/bla/blo/config/file"
                    assert_equal(absolute_path, app.make_path_relative(absolute_path))
                end

                it "converts paths that are present on disk and are prefixed by an entry in search_path" do
                    absolute_path = File.join(app_dir, "path", "to", "file")
                    FileUtils.mkdir_p File.dirname(absolute_path)
                    File.open(absolute_path, "w").close
                    assert_equal("path/to/file", app.make_path_relative(absolute_path))
                end
            end

            describe "#log_base_dir" do
                before do
                    ENV.delete("ROBY_BASE_LOG_DIR")
                    ENV.delete("ROBY_ADD_APP_NAME_TO_BASE_LOG_DIR")
                    app.log.delete("dir")
                end
                after do
                    ENV.delete("ROBY_APP_DIR")
                    ENV.delete("ROBY_ADD_APP_NAME_TO_BASE_LOG_DIR")
                end
                it "it uses log[dir] when no ENV variable is set and log is set" do
                    app.log["dir"] = "strawberry"
                    log_base_dir = app.log_base_dir

                    assert_equal(File.join(app_dir, "strawberry"), log_base_dir)
                end
                it "it uses ROBY_BASE_LOG_DIR with app name if no "\
                   "ROBY_ADD_APP_NAME_TO_BASE_LOG_DIR is set" do
                    ENV["ROBY_BASE_LOG_DIR"] = "pineaple"
                    log_base_dir = app.log_base_dir

                    expected_no_app_base_dir = File.join(app_dir, "pineaple")
                    expected_base_dir = File.join(expected_no_app_base_dir, app.app_name)
                    assert_equal(expected_base_dir, log_base_dir)
                end
                it "it uses ROBY_BASE_LOG_DIR with app name if "\
                   "ROBY_ADD_APP_NAME_TO_BASE_LOG_DIR is set to true" do
                    ENV["ROBY_BASE_LOG_DIR"] = "banana"
                    ENV["ROBY_ADD_APP_NAME_TO_BASE_LOG_DIR"] = "1"
                    log_base_dir = app.log_base_dir

                    expected_no_app_base_dir = File.join(app_dir, "banana")
                    expected_base_dir = File.join(expected_no_app_base_dir, app.app_name)
                    assert_equal(expected_base_dir, log_base_dir)
                end
                it "it uses ROBY_BASE_LOG_DIR without app name if "\
                   "ROBY_ADD_APP_NAME_TO_BASE_LOG_DIR is set to false" do
                    ENV["ROBY_BASE_LOG_DIR"] = "coconut"
                    ENV["ROBY_ADD_APP_NAME_TO_BASE_LOG_DIR"] = "0"
                    log_base_dir = app.log_base_dir

                    expected_no_app_base_dir = File.join(app_dir, "coconut")
                    assert_equal(expected_no_app_base_dir, log_base_dir)
                end
                it "if nothing is set, it defaults to logs as base logs dir" do
                    log_base_dir = app.log_base_dir

                    expected_no_app_base_dir = File.join(app_dir, "logs")
                    assert_equal(expected_no_app_base_dir, log_base_dir)
                end
            end

            describe "log dir lock management" do
                it "checks if a log dir is locked in a concurrent-safe way" do
                    full_path = app.find_and_create_log_dir("tag")
                    app.lock_log_dir
                    app.unlock_log_dir

                    threads = 500.times.map do
                        Thread.new { Application.log_dir_locked?(full_path) }
                    end
                    refute threads.map(&:value).inject(:|)
                end

                it "expects dir to be locked if there is no .lock file" do
                    full_path = app.find_and_create_log_dir("tag")

                    refute File.exist?(File.join(full_path, ".lock"))
                    assert Application.log_dir_locked?(full_path)
                end

                it "expects dir to be locked if .lock file exists and " \
                   "the lock was taken" do
                    full_path = app.find_and_create_log_dir("tag")
                    app.lock_log_dir

                    assert File.exist?(File.join(full_path, ".lock"))
                    assert Application.log_dir_locked?(full_path)
                end

                it "expects dir to not be locked if .lock file exists but " \
                   "lock was not taken" do
                    full_path = app.find_and_create_log_dir("tag")
                    lock_file_path = File.join(full_path, ".lock")
                    File.write(lock_file_path, "")

                    assert File.exist?(lock_file_path)
                    refute Application.log_dir_locked?(full_path)
                end

                it "raises LogDirNotInitialized when trying to lock " \
                   "an unexisting directory" do
                    assert_raises(Roby::Application::LogDirNotInitialized) do
                        app.lock_log_dir
                    end
                end

                it "expects dir to be unlocked after calling unlock_log_dir" do
                    full_path = app.find_and_create_log_dir("tag")
                    app.lock_log_dir
                    app.unlock_log_dir

                    refute Application.log_dir_locked?(full_path)
                end

                it "expects reset_log_dir to remove the lock" do
                    full_path = app.find_and_create_log_dir("tag")
                    app.lock_log_dir
                    app.reset_log_dir

                    refute Application.log_dir_locked?(full_path)
                end
            end

            describe "#find_and_create_log_dir" do
                before do
                    app.log_base_dir = File.join(make_tmpdir, "log", "path")
                end

                it "creates the log directory and paths to it" do
                    full_path = app.find_and_create_log_dir("tag")
                    assert_equal File.join(app.log_base_dir, "tag"), full_path
                    assert File.directory?(full_path)
                end
                it "saves the app metadata in the path" do
                    app.find_and_create_log_dir("tag")
                    metadata = YAML.load(File.read(File.join(app.log_base_dir, "tag", "info.yml")))
                    assert_equal 1, metadata.size
                    assert(metadata.first == app.app_metadata, "#{metadata} differs from #{app.app_metadata}")
                end

                def assert_equal(expected, actual)
                    assert(expected == actual, "#{expected} differs from #{actual}")
                end

                it "registers the created paths for later cleanup" do
                    existing_dirs = app.created_log_dirs.to_set
                    app.find_and_create_log_dir("tag")
                    assert_equal [File.dirname(app.log_base_dir), app.log_base_dir].sort,
                                 app.created_log_base_dirs.to_a.sort
                    assert_equal (existing_dirs | Set[File.join(app.log_base_dir, "tag")]).sort,
                                 app.created_log_dirs.to_a.sort
                end
                it "handles concurrent path creation properly" do
                    FileUtils.mkdir_p app.log_base_dir
                    flexmock(FileUtils).should_receive(:mkdir)
                        .with(File.join(app.log_base_dir, "tag"))
                        .pass_thru { raise Errno::EEXIST }
                    flexmock(FileUtils).should_receive(:mkdir)
                        .with(File.join(app.log_base_dir, "tag.1"))
                        .pass_thru
                    existing_dirs = app.created_log_dirs.to_set
                    created = app.find_and_create_log_dir("tag")
                    assert_equal File.join(app.log_base_dir, "tag.1"), created
                    assert_equal [], app.created_log_base_dirs.to_a
                    assert_equal (existing_dirs | Set[File.join(app.log_base_dir, "tag.1")]).to_a.sort,
                                 app.created_log_dirs.sort
                end
                it "sets app#time_tag to the provided time tag" do
                    app.find_and_create_log_dir("tag")
                    assert_equal "tag", app.time_tag
                end
                it "sets app#log_dir to the created log dir" do
                    full_path = app.find_and_create_log_dir("tag")
                    assert_equal full_path, app.log_dir
                end
                it "handles existing log directories by appending .N suffixes" do
                    FileUtils.mkdir_p File.join(app.log_base_dir, "tag")
                    FileUtils.mkdir_p File.join(app.log_base_dir, "tag.1")
                    full_path = app.find_and_create_log_dir("tag")
                    assert_equal File.join(app.log_base_dir, "tag.2"), full_path
                end
            end

            describe "#test_files_for" do
                attr_reader :base_dir

                before do
                    @base_dir = make_tmpdir
                    app.search_path = [base_dir]
                    create_file("models", "compositions", "file.rb")
                    create_file("test", "compositions", "test_file.rb")
                end

                def create_file(*path)
                    FileUtils.mkdir_p File.join(base_dir, *path[0..-2])
                    FileUtils.touch   File.join(base_dir, *path)
                end

                it "returns a matching test file" do
                    m = flexmock(definition_location: [
                                     flexmock(absolute_path: File.join(base_dir, "models", "compositions", "file.rb"), lineno: 120, label: "m")
                                 ])
                    assert_equal [File.join(base_dir, "test", "compositions", "test_file.rb")],
                                 app.test_files_for(m)
                end
                it "ignores entries not in the search path" do
                    m = flexmock(definition_location: [
                                     flexmock(absolute_path: File.join(base_dir, "models", "compositions", "file.rb"), lineno: 120, label: "m")
                                 ])
                    app.search_path = []
                    assert_equal [], app.test_files_for(m)
                end
                it "ignores entries whose first element is not 'models'" do
                    create_file "compositions", "file.rb"
                    m = flexmock(definition_location: [
                                     flexmock(absolute_path: File.join(base_dir, "compositions", "file.rb"), lineno: 120, label: "m")
                                 ])
                    assert_equal [], app.test_files_for(m)
                end
                it "ignores files that do not exist" do
                    m = flexmock(definition_location: [
                                     flexmock(absolute_path: File.join(base_dir, "models", "compositions", "file.rb"), lineno: 120, label: "m")
                                 ])
                    FileUtils.rm_f File.join(base_dir, "test", "compositions", "test_file.rb")
                    assert_equal [], app.test_files_for(m)
                end
                it "returns all matching entries" do
                    create_file("models", "compositions", "other.rb")
                    create_file("test", "compositions", "test_other.rb")
                    m = flexmock(definition_location: [
                                     flexmock(absolute_path: File.join(base_dir, "models", "compositions", "file.rb"), lineno: 120, label: "m"),
                                     flexmock(absolute_path: File.join(base_dir, "models", "compositions", "other.rb"), lineno: 120, label: "m")
                                 ])
                    assert_equal [File.join(base_dir, "test", "compositions", "test_file.rb"), File.join(base_dir, "test", "compositions", "test_other.rb")],
                                 app.test_files_for(m)
                end
            end

            describe "#find_base_path_for" do
                before do
                    app.search_path = %w{/bla/blo /bla/blo/blu}
                end

                it "returns nil if no entries in search_path matches" do
                    assert_nil app.find_base_path_for("/somewhere/else")
                end
                it "returns the matching entry in search_path" do
                    assert_equal Pathname.new("/bla/blo"), app.find_base_path_for("/bla/blo/models")
                end
                it "returns the longest matching entry in search_path if there are multiple candidates" do
                    assert_equal Pathname.new("/bla/blo/blu"), app.find_base_path_for("/bla/blo/blu/models")
                end
            end

            describe "#setup_robot_names_from_config_dir" do
                def robots_dir
                    File.join(app_dir, "config", "robots")
                end

                describe "the backward-compatible behaviour" do
                    it "does not the robot name resolution to strict if config/robots is empty" do
                        FileUtils.mkdir_p robots_dir
                        app.setup_robot_names_from_config_dir
                        assert !app.robots.strict?
                    end
                    it "does not set the robot name resolution to strict if config/robots does not exist" do
                        app.setup_robot_names_from_config_dir
                        assert !app.robots.strict?
                    end
                end

                describe "the new behaviour" do
                    before do
                        FileUtils.mkdir_p robots_dir
                        File.open(File.join(robots_dir, "test.rb"), "w").close
                        app.setup_robot_names_from_config_dir
                    end
                    it "sets the robot name resolution to strict if config/robots has files" do
                        assert app.robots.strict?
                    end
                    it "registers the robots on #robots" do
                        assert app.robots.has_robot?("test")
                    end
                end
            end
        end

        describe "#prepare_action" do
            it "resolves a task model into an action and adds the actions' #plan_pattern to the plan" do
                task_t = Roby::Task.new_submodel
                task, planner_task = task_t.new, task_t.new
                task.planned_by planner_task
                planner = flexmock
                planning_method = flexmock(plan_pattern: task)
                flexmock(app).should_receive(:action_from_model).with(task_t).and_return([planner, planning_method])

                assert_equal [task, planner_task], app.prepare_action(task_t)
                assert_same app.plan, task.plan
            end

            it "passes arguments to the action" do
                arguments = { id: 10 }

                task_t = Roby::Task.new_submodel
                task, planner_task = task_t.new, task_t.new
                task.planned_by planner_task
                planner = flexmock
                planning_method = flexmock
                planning_method.should_receive(:plan_pattern).with(arguments).once.and_return(task)
                flexmock(app).should_receive(:action_from_model).with(task_t).and_return([planner, planning_method])

                assert_equal [task, planner_task], app.prepare_action(task_t, **arguments)
                assert_same app.plan, task.plan
            end
        end

        describe "#action_from_model" do
            attr_reader :planner
            attr_reader :task_m

            before do
                @planner = flexmock
                @task_m = Roby::Task.new_submodel
                app.planners << planner
            end

            it "raises ArgumentError if there are no matches" do
                planner.should_receive(:find_all_actions_by_type).once
                    .with(task_m).and_return([])
                assert_raises(ArgumentError) { app.action_from_model(task_m) }
            end
            it "returns the action if there is a single match" do
                planner.should_receive(:find_all_actions_by_type).once
                    .with(task_m).and_return([action = flexmock(name: "A")])
                assert_equal [planner, action], app.action_from_model(task_m)
            end
            it "raises if there are more than one match" do
                planner.should_receive(:find_all_actions_by_type).once
                    .with(task_m).and_return([flexmock(name: "A"), flexmock(name: "B")])
                assert_raises(ArgumentError) { app.action_from_model(task_m) }
            end
        end

        describe "shell interface v1 setup" do
            before do
                app.shell_interface_port = 0
            end

            it "binds the shell interface to the configured host and port" do
                flexmock(::TCPServer).should_receive(:new).with("127.0.0.1", 0).pass_thru
                app.shell_interface_host = "127.0.0.1"
                app.setup_shell_interface_v1
                assert_equal "127.0.0.1", app.shell_interface.ip_address
                roby_app_call_interface(port: app.shell_interface.ip_port)
            end
            it "refuses to start a shell interface if one is already setup" do
                app.setup_shell_interface_v1
                assert_raises(RuntimeError) do
                    app.setup_shell_interface_v1
                end
            end
            it "accepts restarting a shell interface after the previous one has been stopped" do
                app.setup_shell_interface_v1
                app.stop_shell_interface
                app.setup_shell_interface_v1
                roby_app_call_interface(port: app.shell_interface.ip_port)
            end
        end

        describe "shell interface v2 setup" do
            before do
                app.shell_interface_v2_port = 0
            end

            it "binds the shell interface to the configured host and port" do
                flexmock(::TCPServer).should_receive(:new).with("127.0.0.1", 0).pass_thru
                app.shell_interface_v2_host = "127.0.0.1"
                app.setup_shell_interface_v2
                assert_equal "127.0.0.1", app.shell_interface_v2.ip_address
                roby_app_call_interface(version: 2, port: app.shell_interface_v2.ip_port)
            end
            it "refuses to start a shell interface if one is already setup" do
                app.setup_shell_interface_v2
                assert_raises(RuntimeError) do
                    app.setup_shell_interface_v2
                end
            end
            it "accepts restarting a shell interface after the previous one has been stopped" do
                app.setup_shell_interface_v2
                app.stop_shell_interface
                app.setup_shell_interface_v2
                roby_app_call_interface(version: 2, port: app.shell_interface_v2.ip_port)
            end
        end

        describe "#start_log_server" do
            attr_reader :logfile_path

            before do
                @logfile_path, writer = roby_app_create_logfile
                writer.close
            end
            after do
                app.stop_log_server
                app.stop_shell_interface
            end

            it "starts the log server on a dynamically allocated port" do
                app.start_log_server(logfile_path)
                refute_equal DRoby::Logfile::Server::DEFAULT_PORT, app.log_server_port
                assert_roby_app_can_connect_to_log_server
            end
            it "gives access to this port through the Roby interface" do
                app.setup_shell_interface_v1
                app.start_log_server(logfile_path)
                actual_port = roby_app_call_interface(&:log_server_port)
                assert_equal app.log_server_port, actual_port
                # synchronize on the log server startup
                assert_roby_app_can_connect_to_log_server
            end
        end

        describe "#load_config_yaml" do
            def create_app_yml(options)
                FileUtils.mkdir_p File.join(app_dir, "config")
                File.open(File.join(app_dir, "config", "app.yml"), "w") do |io|
                    YAML.dump(options, io)
                end
            end
            before do
                app.app_dir = app_dir
                app.robots.strict = false
                app.robots.declare_robot_type "test", "test"
            end

            it "does nothing if it does not find an app.yml file" do
                FileUtils.rm_f File.join(app_dir, "config", "app.yml")
                refute app.load_config_yaml
            end
            it "loads the configuration found in app.yml" do
                before = app.options.dup
                create_app_yml("interface" => "test")
                assert_equal before.merge("interface" => "test"), app.load_config_yaml
            end
            it "merges configuration options in robot-specific sections" do
                before = app.options.dup
                app.robot "test"
                create_app_yml("robots" => Hash["test" => Hash["interface" => "test"]])
                assert_equal before.merge("interface" => "test"), app.load_config_yaml
            end
            it "does a recursive merge for hash entries" do
                app.options["test"] = Hash["kept" => 10, "overriden" => 20]
                app.robot "test"
                create_app_yml("robots" => Hash["test" => Hash["test" => Hash["overriden" => 30]]])
                assert_equal Hash["kept" => 10, "overriden" => 30], app.load_config_yaml["test"]
            end
            it "simply overrides non-hash entries" do
                app.options["overriden"] = 10
                app.robot "test"
                create_app_yml("robots" => Hash["test" => Hash["overriden" => 30]])
                assert_equal 30, app.load_config_yaml["overriden"]
            end
        end

        describe "#apply_config" do
            before do
                flexmock(app)
            end

            it "applies the configuration from the 'interface' key" do
                app.should_receive(:apply_config_interface).with(host_port = flexmock).once
                app.apply_config("interface" => host_port)
            end

            it "falls back to droby.host for backward compatibility" do
                flexmock(Roby).should_receive(:warn_deprecated).with(/droby\.host/).once
                app.should_receive(:apply_config_interface).with(host_port = flexmock).once
                app.apply_config("droby" => Hash["host" => host_port])
            end
        end

        describe "#apply_config_interface" do
            it "parses host and port" do
                app.apply_config_interface("host:23455")
                assert_equal "host", app.shell_interface_host
                assert_equal 23_455, app.shell_interface_port
            end
            it "uses the default interface port if none is specified" do
                app.apply_config_interface("host")
                assert_equal "host", app.shell_interface_host
                assert_equal Interface::DEFAULT_PORT, app.shell_interface_port
            end
            it "sets the host to 'nil' if none is given" do
                app.apply_config_interface(":2354")
                assert_nil app.shell_interface_host
                assert_equal 2354, app.shell_interface_port
            end
        end

        describe "#find_file" do
            it "raises ArgumentError if no path is given" do
                exception = assert_raises(ArgumentError) { app.find_file }
                assert_equal "no path given", exception.message
            end
        end

        describe "#find_files" do
            it "raises ArgumentError if no path is given" do
                exception = assert_raises(ArgumentError) { app.find_files }
                assert_equal "no path given", exception.message
            end
        end

        describe "#find_files_in_dirs" do
            it "raises ArgumentError if no path is given" do
                exception = assert_raises(ArgumentError) { app.find_files_in_dirs }
                assert_equal "no path given", exception.message
            end
        end

        describe "#find_dir" do
            it "raises ArgumentError if no path is given" do
                exception = assert_raises(ArgumentError) { app.find_dir }
                assert_equal "no path given", exception.message
            end
        end

        describe "#find_dirs" do
            it "interprets the first element of search_path "\
               "as being the most specific" do
                least_specific = make_tmppath
                (least_specific / "test").mkdir
                most_specific = make_tmppath
                (most_specific / "test").mkdir
                app.search_path = [most_specific, least_specific].map(&:to_s)
                actual = app.find_dirs("test", all: true, order: :specific_first)

                expected = [most_specific, least_specific].map { |p| (p / "test").to_s }
                assert_equal expected, actual
            end

            it "prioritize root paths over matches from other root paths with " \
               "specific first order" do
                least_specific = make_tmppath
                (least_specific / "default").mkdir
                (least_specific / "default" / "test").mkdir
                most_specific = make_tmppath
                (most_specific / "test").mkdir
                app.search_path = [most_specific, least_specific].map(&:to_s)
                actual = app.find_dirs("ROBOT", "test", all: true, order: :specific_first,
                                                        prioritize_root_paths: true)

                expected = ["#{most_specific}/test", "#{least_specific}/default/test"]
                assert_equal expected, actual
            end

            it "prioritizes root paths over matches from other root paths with " \
               "specific last order" do
                least_specific = make_tmppath
                (least_specific / "default").mkdir
                (least_specific / "default" / "test").mkdir
                most_specific = make_tmppath
                (most_specific / "test").mkdir
                app.search_path = [most_specific, least_specific].map(&:to_s)
                actual = app.find_dirs("ROBOT", "test", all: true, order: :specific_last,
                                                        prioritize_root_paths: true)

                expected = ["#{least_specific}/default/test", "#{most_specific}/test"]
                assert_equal expected, actual
            end

            it "returns the matches ordered by most specific when not prioritizing " \
               "root paths" do
                most_specific = make_tmppath
                (most_specific / "default").mkdir
                (most_specific / "default" / "test").mkdir
                least_specific = make_tmppath
                (least_specific / "test").mkdir
                app.search_path = [least_specific, most_specific].map(&:to_s)
                actual = app.find_dirs("ROBOT", "test", all: true, order: :specific_first,
                                                        prioritize_root_paths: false)

                expected = ["#{most_specific}/default/test", "#{least_specific}/test"]
                assert_equal expected, actual
            end

            it "raises ArgumentError if no path is given" do
                exception = assert_raises(ArgumentError) { app.find_dirs }
                assert_equal "no path given", exception.message
            end
        end

        describe "#self_file?" do
            it "returns true if the file's base path is the app dir" do
                assert app.self_file?(File.join(app_dir, "test", "file"))
            end
            it "returns false if the file's base path is not the app dir" do
                refute app.self_file?("/not/in/app/dir")
            end
        end

        describe "#each_test_file_for_loaded_models" do
            before do
                gen_app
            end

            describe "included models" do
                attr_reader :task_m, :path

                before do
                    @task_m = Roby::Task.new_submodel(name: "Test")
                    flexmock(app).should_receive(:test_files_for)
                        .with(task_m).once
                        .and_return([@path = flexmock])
                    flexmock(app).should_receive(:test_files_for)
                        .and_return([])
                end

                it "registers models using #test_files_for" do
                    assert_equal [[path, Set[task_m].to_set]], app.each_test_file_for_loaded_models.to_a
                end
                it "registers models that private_specializations? defined but are not specialized" do
                    flexmock(task_m).should_receive(:private_specialization?).explicitly
                        .and_return(false)
                    assert_equal [[path, Set[task_m].to_set]], app.each_test_file_for_loaded_models.to_a
                end
            end

            describe "ignored models" do
                attr_reader :task_m

                before do
                    @task_m = Roby::Task.new_submodel(name: "Test")
                    flexmock(app).should_receive(:test_files_for)
                        .with(task_m).never
                    flexmock(app).should_receive(:test_files_for)
                        .and_return([])
                end

                it "ignores models that have no names" do
                    flexmock(task_m).should_receive(:name)
                    assert_equal [], app.each_test_file_for_loaded_models.to_a
                end

                it "ignores event models" do
                    flexmock(task_m).should_receive(:has_ancestor?)
                        .with(Roby::Event).and_return(true)
                    assert_equal [], app.each_test_file_for_loaded_models.to_a
                end

                it "ignores private specializations" do
                    flexmock(task_m).should_receive(:private_specialization?)
                        .explicitly.and_return(true)
                    assert_equal [], app.each_test_file_for_loaded_models.to_a
                end
            end
        end

        describe "each_test_file_in_app" do
            before do
                gen_app
                FileUtils.touch File.join(app_dir, "config", "robots", "current_robot.rb")
            end

            it "enumerates test files in test/ recursively" do
                paths = touch_test_files \
                    %w[test_root.rb],
                    %w[subdir test_subdir.rb]
                paths << File.join(app_dir, "test", "robots", "test_default.rb")
                assert_equal paths, app.each_test_file_in_app.to_set
            end

            it "ignores the paths that do not match test_*.rb" do
                touch_test_files \
                    %w[root_test_root.rb],
                    %w[subdir subdir.rb]
                path = File.join(app_dir, "test", "robots", "test_default.rb")
                assert_equal [path], app.each_test_file_in_app.to_a
            end

            it "only loads the test file in test/robots/ that match the current "\
               "robot name" do
                touch_test_files \
                    %w[robots test_current_robot.rb],
                    %w[robots test_some_robot.rb],
                    %w[robots test_another_robot.rb]
                app.robots.robots["current_robot"] = "current_robot"
                app.robot "current_robot"
                path = File.join(app_dir, "test", "robots", "test_current_robot.rb")
                assert_equal [path], app.each_test_file_in_app.to_a
            end

            it "falls back to the robot type test if there is one and none for the "\
               "robot type" do
                touch_test_files \
                    %w[robots test_current_robot_type.rb],
                    %w[robots test_some_robot.rb],
                    %w[robots test_another_robot.rb]
                app.robots.robots["current_robot"] = "current_robot_type"
                app.robot "current_robot", "current_robot_type"
                path = File.join(app_dir, "test", "robots", "test_current_robot_type.rb")
                assert_equal [path], app.each_test_file_in_app.to_a
            end

            it "does not load any robot test if there is none matching" do
                touch_test_files \
                    %w[robots test_current_robot_type.rb],
                    %w[robots test_some_robot.rb],
                    %w[robots test_another_robot.rb]
                app.robots.robots["current_robot"] = "some_other_type"
                app.robot "current_robot", "some_other_type"
                assert_equal [], app.each_test_file_in_app.to_a
            end
        end

        describe ".common_optparse_setup" do
            attr_reader :parser

            before do
                @parser = OptionParser.new
                Application.common_optparse_setup(parser)
            end

            describe "--set" do
                it "sets the specified configuration parameter to the given value" do
                    parser.parse(["--set=a=10"])
                    assert_equal 10, Conf.a
                end
                it "parses words separated by dots as a chain of elements in the conf structure" do
                    parser.parse(["--set=a.deep.value=10"])
                    assert_equal 10, Conf.a.deep.value
                end
                it "parses the value in YAML" do
                    flexmock(YAML).should_receive(:load)
                        .with("random_string").and_return(value = flexmock)
                    parser.parse(["--set=a.deep.value=random_string"])
                    assert_equal value, Conf.a.deep.value
                end
            end
        end

        describe "#log_current_dir" do
            before do
                @app = Application.new
            end
            it "returns #log_dir if it is set" do
                app.log_dir = make_tmpdir
                assert_equal app.log_dir, app.log_current_dir
            end
            describe "discovery through the 'current' symlink" do
                attr_reader :log_dir, :current_path

                before do
                    app.log_base_dir = make_tmpdir
                    @log_dir = make_tmpdir
                    @current_path = File.join(app.log_base_dir, "current")
                end
                it "resolves the symlink ${log_current_dir}/current" do
                    FileUtils.ln_s log_dir, current_path
                    assert_equal log_dir, app.log_current_dir
                end
                it "raises ArgumentError if there is no symlink" do
                    error = assert_raises(ArgumentError) { app.log_current_dir }
                    assert_equal "#{current_path} does not exist or is not a symbolic link",
                                 error.message
                end
                it "raises ArgumentError if the link is not a symlink" do
                    FileUtils.touch current_path
                    error = assert_raises(ArgumentError) { app.log_current_dir }
                    assert_equal "#{current_path} does not exist or is not a symbolic link",
                                 error.message
                end
                it "raises ArgumentError if the link points to a non-existent directory" do
                    log_dir = File.join(self.log_dir, "test")
                    FileUtils.ln_s log_dir, current_path
                    error = assert_raises(ArgumentError) { app.log_current_dir }
                    assert_equal "#{current_path} points to #{log_dir}, which does not exist",
                                 error.message
                end
                it "raises ArgumentError if the link does not point to a directory" do
                    FileUtils.touch(log_dir = File.join(self.log_dir, "test"))
                    FileUtils.ln_s log_dir, current_path
                    error = assert_raises(ArgumentError) { app.log_current_dir }
                    assert_equal "#{current_path} points to #{log_dir}, which is not a directory",
                                 error.message
                end
            end
        end

        describe "#log_read_metadata" do
            it "returns an empty array if the current log directory cannot be determined" do
                flexmock(app).should_receive(:log_current_dir).and_raise(ArgumentError)
                assert_equal [], app.log_read_metadata
            end
            it "returns an empty array if the log directory does not have an info.yml file" do
                app.log_dir = make_tmpdir
                assert_equal [], app.log_read_metadata
            end
            it "returns the unmarshalled contents of the info.yml file" do
                app.log_dir = make_tmpdir
                File.open(File.join(app.log_dir, "info.yml"), "w") do |io|
                    YAML.dump(Hash["test" => true], io)
                end
                assert_equal Hash["test" => true], app.log_read_metadata
            end
        end

        describe ".host_options" do
            before do
                @opt = OptionParser.new
            end
            it "sets the host/port pair if both are given" do
                Application.host_options(@opt, options = Hash[host: "test", port: 666])
                @opt.parse(["--host=bla:90"])
                assert_equal "bla", options[:host]
                assert_equal 90, options[:port]
            end
            it "sets only the host and leaves the port if no port is given" do
                Application.host_options(@opt, options = Hash[host: "test", port: 666])
                @opt.parse(["--host=bla"])
                assert_equal "bla", options[:host]
                assert_equal 666, options[:port]
            end
            it "does not modify the options if no --host argument is given" do
                Application.host_options(@opt, options = Hash[host: "test", port: 666])
                @opt.parse([])
                assert_equal "test", options[:host]
                assert_equal 666, options[:port]
            end
        end

        describe "UI event notification" do
            it "allows to register a callback for UI events" do
                recorder = flexmock
                recorder.should_receive(:called).with(:test_event, [0, 2, 3]).once
                app.on_ui_event do |event, *args|
                    recorder.called(event, args)
                end
                app.ui_event(:test_event, 0, 2, 3)
            end
            it "allows to deregister a previously installed callback" do
                recorder = flexmock
                recorder.should_receive(:called).never
                id = app.on_ui_event do |event, *args|
                    recorder.called
                end
                app.remove_ui_event_listener(id)
                app.ui_event(:test_event, 0, 2, 3)
            end
        end

        describe "the search path management" do
            before do
                @load_path = $LOAD_PATH.dup
            end

            after do
                $LOAD_PATH.clear
                $LOAD_PATH.concat(@load_path)
            end

            describe "update_load_path" do
                before do
                    @test_dir_0 = make_tmpdir
                    @test_dir_1 = make_tmpdir
                    app.search_path = [@test_dir_0, @test_dir_1]
                end
                it "injects the app dir with the same precedence than the search path" do
                    app.update_load_path
                    assert_equal @test_dir_0, $LOAD_PATH[0]
                    assert_equal @test_dir_1, $LOAD_PATH[1]
                end
                it "injects the app's lib dirs if they exist with the same precedence than the search path" do
                    FileUtils.mkdir File.join(@test_dir_0, "lib")
                    app.update_load_path
                    assert_equal File.join(@test_dir_0, "lib"), $LOAD_PATH[0]
                    assert_equal @test_dir_0, $LOAD_PATH[1]
                    assert_equal @test_dir_1, $LOAD_PATH[2]
                end
                it "enforces the ordering even if an app's dir is already present in the load path" do
                    $LOAD_PATH.unshift @test_dir_0
                    app.update_load_path
                    assert_equal @test_dir_0, $LOAD_PATH[0]
                    assert_equal @test_dir_1, $LOAD_PATH[1]
                end
            end

            describe "prepend_search_path" do
                before do
                    @app_dir = make_tmpdir
                    @test_dir_1 = make_tmpdir
                    @test_dir_2 = make_tmpdir
                    app.app_dir = @app_dir
                end

                it "initializes the search_path ivar first" do
                    app.prepend_search_path @test_dir_1
                    assert_equal [@test_dir_1, @app_dir], app.search_path
                end

                it "adds a new path at the top of the list and updates LOAD_PATH" do
                    app.search_path = [@app_dir, @test_dir_1]
                    app.prepend_search_path @test_dir_2
                    assert_equal [@test_dir_2, @app_dir, @test_dir_1], app.search_path
                    assert_equal [@test_dir_2, @app_dir, @test_dir_1], $LOAD_PATH[0, 3]
                end
            end

            describe "shift_search_path" do
                before do
                    @app_dir = make_tmpdir
                    @test_dir_1 = make_tmpdir
                    @test_dir_2 = make_tmpdir
                    app.app_dir = @app_dir
                end

                it "initializes the search_path ivar first" do
                    app.shift_search_path @test_dir_1
                    assert_equal [@app_dir, @test_dir_1], app.search_path
                end

                it "adds a new path just after the app dir and updates LOAD_PATH" do
                    app.search_path = [@app_dir, @test_dir_1]
                    app.shift_search_path @test_dir_2
                    assert_equal [@app_dir, @test_dir_2, @test_dir_1], app.search_path
                    assert_equal [@app_dir, @test_dir_2, @test_dir_1], $LOAD_PATH[0, 3]
                end
            end

            describe "push_search_path" do
                before do
                    @app_dir = make_tmpdir
                    @test_dir_1 = make_tmpdir
                    @test_dir_2 = make_tmpdir
                    app.app_dir = @app_dir
                end

                it "initializes the search_path ivar first" do
                    app.push_search_path @test_dir_1
                    assert_equal [@app_dir, @test_dir_1], app.search_path
                end

                it "adds a new path just after the app dir and updates LOAD_PATH" do
                    app.search_path = [@app_dir, @test_dir_1]
                    app.push_search_path @test_dir_2
                    assert_equal [@app_dir, @test_dir_1, @test_dir_2], app.search_path
                    assert_equal [@app_dir, @test_dir_1, @test_dir_2], $LOAD_PATH[0, 3]
                end
            end

            describe "register_app" do
                before do
                    @root = make_tmpdir
                    @app_dir = File.join(@root, "app")
                    @required_app_dir = File.join(@root, "required")
                    app.app_dir = @app_dir
                end

                it "registers the full path in the search path, pushing it by default" do
                    flexmock(app).should_receive(:push_search_path).once.pass_thru
                    app.register_app("../required")
                    assert_equal [@app_dir, @required_app_dir], app.search_path
                end

                it "allows to change where the new path is inserted" do
                    flexmock(app).should_receive(:prepend_search_path).once.pass_thru
                    app.register_app("../required", where: :prepend)
                    assert_equal [@required_app_dir, @app_dir], app.search_path
                end
            end
        end

        describe "#setup_rest_interface" do
            before do
                @app = Roby::Application.new
                @app.rest_interface_port = 0
            end
            after do
                @app.stop_rest_interface
            end
            it "starts the REST server" do
                server = nil
                capture_log(Robot, :info) { server = @app.setup_rest_interface }
                assert_same @app, server.app
                server.wait_start
                execute_in_thread { server.server_alive? }
            end
            it "allows to extend the API through plugins" do
                plugin = Module.new do
                    def self.setup_rest_interface(app, api)
                        api.get("/extended") { 42 }
                    end
                end
                @app.add_plugin "test", plugin
                server = nil
                capture_log(Robot, :info) { server = @app.setup_rest_interface }
                server.wait_start
                returned_value = execute_in_thread do
                    RestClient
                    .get("http://localhost:#{server.port}/api/extended")
                end
                assert_equal 42, Integer(returned_value)
            end

            def execute_in_thread(plan: @app.plan, &block)
                p = plan.execution_engine.promise(&block)
                execute(plan: plan) { p.execute }
                p.value!
            end
        end

        describe "setup of loggers" do
            before do
                @app = Roby::Application.new
                @app.plugins_enabled = false
                @app.app_dir = make_tmpdir
                gen_app(@app.app_dir)
            end

            after do
                if Roby.const_defined?(:LoggerSetupTests)
                    Roby.module_eval do
                        remove_const :LoggerSetupTests
                    end
                end
            end

            describe "during base configuration loading" do
                before do
                    Roby.const_set :LoggerSetupTests,
                                   LoggerContext.new(@formatter = flexmock)
                end

                it "sets up the log levels" do
                    @app.log_setup "roby/logger_setup_tests", "DEBUG"
                    @app.load_base_config
                    assert_equal Logger::DEBUG, Roby::LoggerSetupTests.logger.level
                end
                it "ignores absent contexts" do
                    @app.log_setup "roby/does_not_exist", "DEBUG"
                    @app.load_base_config
                end
                it "does not redirect to files" do
                    @app.log_setup "roby/logger_setup_tests", "DEBUG:file"
                    @app.load_base_config
                    flexmock(STDOUT).should_receive(:write).once
                    LoggerSetupTests.logger << "bla"
                end
            end

            describe "during base_setup" do
                def assert_handles_plugin_hook(hook_name)
                    plugin = Module.new
                    plugin.singleton_class.class_eval do
                        define_method(hook_name) do |app|
                            Roby.const_set :LoggerSetupTests,
                                           LoggerContext.new(@formatter = ->(s) { "" })
                        end
                    end
                    @app.log_setup "roby/logger_setup_tests", "DEBUG"
                    @app.add_plugin "test", plugin
                    @app.base_setup
                    assert_equal Logger::DEBUG, Roby::LoggerSetupTests.logger.level
                end
                it "sets up contexts that are created during plugin's load_base_config" do
                    assert_handles_plugin_hook :load_base_config
                end

                def assert_handles_robot_hook(hook_name)
                    @app.log_setup "roby/logger_setup_tests", "DEBUG"
                    @app.send(hook_name) do
                        Roby.const_set :LoggerSetupTests,
                                       LoggerContext.new(@formatter = flexmock)
                    end
                    @app.base_setup
                    assert_equal Logger::DEBUG, Roby::LoggerSetupTests.logger.level
                end
                it "sets up contexts that are created during robot init" do
                    assert_handles_robot_hook :on_init
                end
                it "raises for missing contexts" do
                    @app.log_setup "roby/logger_setup_tests", "DEBUG"
                    assert_raises(Application::InvalidLoggerName) do
                        @app.setup
                    end
                end
                it "sets up redirections to files" do
                    Roby.const_set :LoggerSetupTests,
                                   LoggerContext.new(@formatter = ->(s) { s })
                    @app.log_setup "roby/logger_setup_tests", "DEBUG:file.txt"
                    @app.log_dir = make_tmpdir
                    flexmock(Robot).should_receive(:info).with(/^redirected logger for #{Roby::LoggerSetupTests} to #{File.join(@app.log_dir, 'file.txt')}/)
                    @app.setup
                    Roby::LoggerSetupTests.logger << "TEST"
                    assert_equal "TEST", File.read(File.join(@app.log_dir, "file.txt"))
                end
            end
        end

        describe "#run" do
            after do
                if @run_thread
                    join_run_thread
                end
            end

            def start_run_thread(report_on_exception: true)
                @run_sync = Concurrent::CyclicBarrier.new(2)
                @app.execution_engine.once do
                    @run_sync.wait
                    @run_sync.wait
                    yield if block_given?
                end
                @run_thread = Thread.new do
                    if (t = Thread.current).respond_to?(:report_on_exception=)
                        t.report_on_exception = report_on_exception
                    end
                    @app.run
                end
                Thread.pass until @run_thread.stop?
                @run_sync.wait
            end

            def join_run_thread
                @app.execution_engine.quit
                @run_sync.wait
                @run_thread.join
            ensure
                @run_thread = nil
            end

            it "handles properly if the engine's run method raises unexpectedly" do
                error = Class.new(RuntimeError).exception("test")
                flexmock(@app.execution_engine).should_receive(:run)
                    .and_raise(error)
                run_thread = Thread.new do
                    if (t = Thread.current).respond_to?(:report_on_exception=)
                        t.report_on_exception = false
                    end
                    @app.run
                end
                assert_raises(error.class) do
                    run_thread.join
                end
            end

            it "handles properly if the engine quits with a framework error" do
                error = Class.new(RuntimeError).exception("test")
                fatal_log = capture_log(@app.execution_engine, :fatal) do
                    start_run_thread(report_on_exception: false) do
                        @app.execution_engine.add_framework_error(error, "test")
                    end
                    assert_raises(error.class) do
                        join_run_thread
                    end
                end
                assert fatal_log.grep(/Application error in test/)
                assert fatal_log.grep(/test ()/)
                assert fatal_log.grep(/Exefcution thread FORCEFULLY quitting/)
                assert fatal_log.grep(/in test: test ()/)
            end

            describe "the --set option" do
                before do
                    gen_app
                    @config_path = File.join(app_dir, "config", "robots", "default.rb")
                end

                it "is supported by check" do
                    File.open(@config_path, "a") do |io|
                        io.puts <<~CONTROLLER
                            Robot.requires { puts "TEST: \#{Conf.some.field}" }
                        CONTROLLER
                    end

                    out_r, out_w = IO.pipe
                    roby_app_spawn("check", "--set", "some.field=42", out: out_w)
                    out_w.close
                    output = out_r.read
                    assert_equal "TEST: 42\n", output
                end

                it "re-applies the given configuration parameters on reload" do
                    File.open(@config_path, "a") do |io|
                        io.puts <<~CONTROLLER
                            Robot.requires do
                                STDOUT.sync = true

                                unless File.file?("already_loaded")
                                    puts "TEST: \#{Conf.some.field}"
                                    Conf.some.delete :field
                                    puts "TEST: DELETED"
                                    Roby.app.reload_config
                                    puts "TEST: \#{Conf.some.field}"
                                    FileUtils.touch "already_loaded"
                                end
                            end
                        CONTROLLER
                    end

                    out_r, out_w = IO.pipe
                    roby_app_spawn("check", "--set", "some.field=42", out: out_w)
                    out_w.close
                    output = out_r.read
                    assert_equal "TEST: 42\nTEST: DELETED\nTEST: 42\n", output
                end

                it "is supported by run" do
                    File.open(@config_path, "a") do |io|
                        io.puts <<~CONTROLLER
                            Robot.requires { puts "TEST: \#{Conf.some.field}" }
                        CONTROLLER
                    end

                    out_r, out_w = IO.pipe
                    pid, iface =
                        roby_app_start("run", "--set", "some.field=42", out: out_w)
                    out_w.close
                    assert_roby_app_quits(pid, interface: iface)
                    output = out_r.read
                    assert_match(/TEST: 42/, output)
                end
            end
        end

        describe "#controller" do
            it 'registers the block into the "controllers" set' do
                block = -> { true }
                app.controller(&block)
                assert_equal [block], app.controllers.map(&:block)
            end

            it "appends new blocks to the existing list" do
                block0 = -> { true }
                block1 = -> { true }
                app.controller(&block0)
                app.controller(&block1)
                assert_equal [block0, block1], app.controllers.map(&:block)
            end

            it "removes existing blocks if reset is true" do
                block0 = -> { true }
                block1 = -> { true }
                app.controller(&block0)
                app.controller(reset: true, &block1)
                assert_equal [block1], app.controllers.map(&:block)
            end
        end

        def touch_test_files(*paths)
            paths.map do |p|
                full_p = File.join(app.app_dir, "test", *p)
                FileUtils.mkdir_p File.dirname(full_p)
                FileUtils.touch full_p
                full_p
            end.to_set
        end
    end
end
