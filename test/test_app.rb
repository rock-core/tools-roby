require 'roby/test/self'
require 'roby/test/roby_app_helpers'
require 'roby/droby/logfile/writer'
require 'roby/droby/logfile/client'
require 'roby/app/installer'

module Roby
    describe Application do
        include Test::RobyAppHelpers

        describe "filesystem access and resolution" do
            before do
                app.search_path = [app_dir]
            end

            describe ".guess_app_dir" do
                after do
                    ENV.delete('ROBY_APP_DIR')
                end
                it "resolves the ROBY_APP_DIR environment variable if given" do
                    Installer.install(app, quiet: true)
                    ENV['ROBY_APP_DIR'] = app_dir
                    assert_equal app_dir, Application.guess_app_dir
                end
                it "raises if ROBY_APP_DIR points to a directory that is not a valid Roby app" do
                    ENV['ROBY_APP_DIR'] = app_dir
                    assert_raises(Application::InvalidRobyAppDirEnv) do
                        Application.guess_app_dir
                    end
                end
                it "returns Dir.pwd if it is the root of a Roby application" do
                    Installer.install(app, quiet: true)
                    FlexMock.use(Dir) do |mock|
                        mock.should_receive(:pwd).and_return(app_dir)
                        assert_equal app_dir, Application.guess_app_dir
                    end
                end
                it "looks for a roby application starting at the current working directory" do
                    Installer.install(app, quiet: true)
                    FileUtils.mkdir_p(path = File.join(app_dir, 'test', 'path', 'in', 'app'))
                    FlexMock.use(Dir) do |mock|
                        mock.should_receive(:pwd).and_return(path)
                        assert_equal app_dir, Application.guess_app_dir
                    end
                end
                it "returns nil if Dir.pwd is not within a valid application " do
                    FileUtils.mkdir_p(path = File.join(app_dir, 'test', 'path', 'in', 'app'))
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
                    absolute_path = File.join(app_dir, 'path', 'to', 'file')
                    FileUtils.mkdir_p File.dirname(absolute_path)
                    File.open(absolute_path, 'w').close
                    assert_equal("path/to/file", app.make_path_relative(absolute_path))
                end
            end

            describe "#find_and_create_log_dir" do
                before do
                    app.log_base_dir = File.join(make_tmpdir, 'log', 'path')
                end

                it "creates the log directory and paths to it" do
                    full_path = app.find_and_create_log_dir('tag')
                    assert_equal File.join(app.log_base_dir, 'tag'), full_path
                    assert File.directory?(full_path)
                end
                it "saves the app metadata in the path" do
                    app.find_and_create_log_dir('tag')
                    metadata = YAML.load(File.read(File.join(app.log_base_dir, 'tag', 'info.yml')))
                    assert_equal 1, metadata.size
                    assert(metadata.first == app.app_metadata, "#{metadata} differs from #{app.app_metadata}")
                end

                def assert_equal(expected, actual)
                    assert(expected == actual, "#{expected} differs from #{actual}")
                end

                it "registers the created paths for later cleanup" do
                    existing_dirs = app.created_log_dirs.to_set
                    app.find_and_create_log_dir('tag')
                    assert_equal [File.dirname(app.log_base_dir), app.log_base_dir].to_set,
                        app.created_log_base_dirs.to_set
                    assert_equal existing_dirs | Set[File.join(app.log_base_dir, 'tag')],
                        app.created_log_dirs.to_set
                end
                it "handles concurrent path creation properly" do
                    FileUtils.mkdir_p app.log_base_dir
                    flexmock(FileUtils).should_receive(:mkdir).
                        with(File.join(app.log_base_dir, 'tag')).
                        pass_thru { raise Errno::EEXIST }
                    flexmock(FileUtils).should_receive(:mkdir).
                        with(File.join(app.log_base_dir, 'tag.1')).
                        pass_thru
                    existing_dirs = app.created_log_dirs.to_set
                    created = app.find_and_create_log_dir('tag')
                    assert_equal File.join(app.log_base_dir, 'tag.1'), created
                    assert_equal [].to_set, app.created_log_base_dirs.to_set
                    assert_equal existing_dirs | Set[File.join(app.log_base_dir, 'tag.1')],
                        app.created_log_dirs.to_set
                end
                it "sets app#time_tag to the provided time tag" do
                    app.find_and_create_log_dir('tag')
                    assert_equal 'tag', app.time_tag
                end
                it "sets app#log_dir to the created log dir" do
                    full_path = app.find_and_create_log_dir('tag')
                    assert_equal full_path, app.log_dir
                end
                it "handles existing log directories by appending .N suffixes" do
                    FileUtils.mkdir_p File.join(app.log_base_dir, 'tag')
                    FileUtils.mkdir_p File.join(app.log_base_dir, 'tag.1')
                    full_path = app.find_and_create_log_dir('tag')
                    assert_equal File.join(app.log_base_dir, 'tag.2'), full_path
                end
            end

            describe "#test_file_for" do
                attr_reader :base_dir

                before do
                    @base_dir = make_tmpdir
                    app.search_path = [base_dir]
                    create_file('models', 'compositions', 'file.rb')
                    create_file('test', 'compositions', 'test_file.rb')
                end

                def create_file(*path)
                    FileUtils.mkdir_p File.join(base_dir, *path[0..-2])
                    FileUtils.touch   File.join(base_dir, *path)
                end

                it "returns a matching test file" do
                    m = flexmock(definition_location: [
                        flexmock(absolute_path: File.join(base_dir, 'models', 'compositions', 'file.rb'), lineno: 120, label: 'm')
                    ])
                    assert_equal File.join(base_dir, 'test', 'compositions', 'test_file.rb'),
                        app.test_file_for(m)
                end
                it "ignores entries not in the search path" do
                    m = flexmock(definition_location: [
                        flexmock(absolute_path: File.join(base_dir, 'models', 'compositions', 'file.rb'), lineno: 120, label: 'm')
                    ])
                    app.search_path = []
                    assert_equal nil, app.test_file_for(m)
                end
                it "ignores entries whose first element is not 'models'" do
                    create_file 'compositions', 'file.rb'
                    m = flexmock(definition_location: [
                        flexmock(absolute_path: File.join(base_dir, 'compositions', 'file.rb'), lineno: 120, label: 'm')
                    ])
                    assert_equal nil, app.test_file_for(m)
                end
                it "returns nil if the expected test file does not exist" do
                    m = flexmock(definition_location: [
                        flexmock(absolute_path: File.join(base_dir, 'models', 'compositions', 'file.rb'), lineno: 120, label: 'm')
                    ])
                    FileUtils.rm_f File.join(base_dir, 'test', 'compositions', 'test_file.rb')
                    assert_equal nil, app.test_file_for(m)
                end
            end

            describe "#find_base_path_for" do
                before do
                    app.search_path = %w{/bla/blo /bla/blo/blu}
                end

                it "returns nil if no entries in search_path matches" do
                    assert_equal nil, app.find_base_path_for("/somewhere/else")
                end
                it "returns the matching entry in search_path" do
                    assert_equal "/bla/blo", app.find_base_path_for("/bla/blo/models")
                end
                it "returns the longest matching entry in search_path if there are multiple candidates" do
                    assert_equal "/bla/blo/blu", app.find_base_path_for("/bla/blo/blu/models")
                end
            end

            describe "#setup_robot_names_from_config_dir" do
                def robots_dir
                    File.join(app_dir, 'config', 'robots')
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
                        File.open(File.join(robots_dir, "test.rb"), 'w').close
                        app.setup_robot_names_from_config_dir
                    end
                    it "sets the robot name resolution to strict if config/robots has files" do
                        assert app.robots.strict?
                    end
                    it "registers the robots on #robots" do
                        assert app.robots.has_robot?('test')
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
                arguments = {id: 10}

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
                planner.should_receive(:find_all_actions_by_type).once.
                    with(task_m).and_return([])
                assert_raises(ArgumentError) { app.action_from_model(task_m) }
            end
            it "returns the action if there is a single match" do
                planner.should_receive(:find_all_actions_by_type).once.
                    with(task_m).and_return([action = flexmock(name: 'A')])
                assert_equal [planner, action], app.action_from_model(task_m)
            end
            it "raises if there are more than one match" do
                planner.should_receive(:find_all_actions_by_type).once.
                    with(task_m).and_return([flexmock(name: 'A'), flexmock(name: 'B')])
                assert_raises(ArgumentError) { app.action_from_model(task_m) }
            end
        end

        describe "shell interface setup" do
            it "binds the shell interface to the value specified in #shell_interface_host" do
                flexmock(::TCPServer).should_receive(:new).with('127.0.0.1', Interface::DEFAULT_PORT).pass_thru
                app.shell_interface_host = '127.0.0.1'
                app.setup_shell_interface
                assert_equal '127.0.0.1', app.shell_interface.ip_address
                roby_app_call_interface
            end
            it "starts the shell interface on the port specified by #shell_interface_port" do
                flexmock(::TCPServer).should_receive(:new).with(nil, 0).pass_thru
                app.shell_interface_port = 0
                app.setup_shell_interface
                roby_app_call_interface(port: app.shell_interface.ip_port)
            end
            it "refuses to start a shell interface if one is already setup" do
                app.setup_shell_interface
                assert_raises(RuntimeError) do
                    app.setup_shell_interface
                end
            end
            it "accepts restarting a shell interface after the previous one has been stopped" do
                app.setup_shell_interface
                app.stop_shell_interface
                app.setup_shell_interface
                roby_app_call_interface(port: app.shell_interface.ip_port)
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
                app.setup_shell_interface
                app.start_log_server(logfile_path)
                actual_port = roby_app_call_interface do |interface|
                    interface.log_server_port
                end
                assert_equal app.log_server_port, actual_port
                # synchronize on the log server startup
                assert_roby_app_can_connect_to_log_server 
            end
        end

        describe "#load_config_yaml" do
            def create_app_yml(options)
                FileUtils.mkdir_p File.join(app_dir, 'config')
                File.open(File.join(app_dir, 'config', 'app.yml'), 'w') do |io|
                    YAML.dump(options, io)
                end
            end
            before do
                app.app_dir = app_dir
                app.robots.strict = false
                app.robots.declare_robot_type 'test', 'test'
            end

            it "does nothing if it does not find an app.yml file" do
                FileUtils.rm_f File.join(app_dir, "config", "app.yml")
                refute app.load_config_yaml
            end
            it "loads the configuration found in app.yml" do
                before = app.options.dup
                create_app_yml('interface' => 'test')
                assert_equal before.merge('interface' => 'test'), app.load_config_yaml
            end
            it "merges configuration options in robot-specific sections" do
                before = app.options.dup
                app.robot 'test'
                create_app_yml('robots' => Hash['test' => Hash['interface' => 'test']])
                assert_equal before.merge('interface' => 'test'), app.load_config_yaml
            end
            it "does a recursive merge for hash entries" do
                before = app.options.dup
                app.options['test'] = Hash['kept' => 10, 'overriden' => 20]
                app.robot 'test'
                create_app_yml('robots' => Hash['test' => Hash['test' => Hash['overriden' => 30]]])
                assert_equal Hash['kept' => 10, 'overriden' => 30], app.load_config_yaml['test']
            end
            it "simply overrides non-hash entries" do
                before = app.options.dup
                app.options['overriden'] = 10
                app.robot 'test'
                create_app_yml('robots' => Hash['test' => Hash['overriden' => 30]])
                assert_equal 30, app.load_config_yaml['overriden']
            end
        end

        describe "#apply_config" do
            before do
                flexmock(app)
            end

            it "applies the configuration from the 'interface' key" do
                app.should_receive(:apply_config_interface).with(host_port = flexmock).once
                app.apply_config('interface' => host_port)
            end

            it "falls back to droby.host for backward compatibility" do
                flexmock(Roby).should_receive(:warn_deprecated).with(/droby\.host/).once
                app.should_receive(:apply_config_interface).with(host_port = flexmock).once
                app.apply_config('droby' => Hash['host' => host_port])
            end
        end

        describe "#apply_config_interface" do
            it "parses host and port" do
                app.apply_config_interface('host:23455')
                assert_equal 'host', app.shell_interface_host
                assert_equal 23455, app.shell_interface_port
            end
            it "uses the default interface port if none is specified" do
                app.apply_config_interface('host')
                assert_equal 'host', app.shell_interface_host
                assert_equal Interface::DEFAULT_PORT, app.shell_interface_port
            end
            it "sets the host to 'nil' if none is given" do
                app.apply_config_interface(':2354')
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
            it "raises ArgumentError if no path is given" do
                exception = assert_raises(ArgumentError) { app.find_dirs }
                assert_equal "no path given", exception.message
            end
        end

        describe "#each_test_file" do
            attr_reader :app
            before do
                @app = Roby::Application.new
                app.app_dir = make_tmpdir
                installer = Roby::Installer.new(app, quiet: true)
                installer.install
            end

            describe "included models" do
                attr_reader :task_m, :path

                before do
                    @task_m = Roby::Task.new_submodel(name: 'Test')
                    flexmock(app).should_receive(:test_file_for).
                        with(task_m).once.
                        and_return(@path = flexmock)
                    flexmock(app).should_receive(:test_file_for)
                end

                it "registers models using #test_file_for" do
                    assert_equal [[path, Set[task_m].to_set]], app.each_test_file.to_a
                end
                it "registers models that private_specializations? defined but are not specialized" do
                    flexmock(task_m).should_receive(:private_specialization?).explicitly.
                        and_return(false)
                    assert_equal [[path, Set[task_m].to_set]], app.each_test_file.to_a
                end
            end

            describe "ignored models" do
                attr_reader :task_m

                before do
                    @task_m = Roby::Task.new_submodel(name: 'Test')
                    flexmock(app).should_receive(:test_file_for).
                        with(task_m).never
                    flexmock(app).should_receive(:test_file_for)
                end

                it "ignores models that have no names" do
                    flexmock(task_m).should_receive(:name)
                    assert_equal [], app.each_test_file.to_a
                end

                it "ignores event models" do
                    flexmock(task_m).should_receive(:has_ancestor?).
                        with(Roby::Event).and_return(true)
                    assert_equal [], app.each_test_file.to_a
                end

                it "ignores private specializations" do
                    flexmock(task_m).should_receive(:private_specialization?).
                        explicitly.and_return(true)
                    assert_equal [], app.each_test_file.to_a
                end
            end

            describe "lib tests" do
                before do
                    flexmock(app).should_receive(:test_file_for)
                end

                def touch_test_files(*paths)
                    paths.map do |p|
                        full_p = File.join(app.app_dir, 'test', 'lib', *p)
                        FileUtils.mkdir_p File.dirname(full_p)
                        FileUtils.touch full_p
                        [full_p, Set.new]
                    end
                end

                it "enumerates test_*.rb files in test/lib" do
                    expected = touch_test_files \
                        ['test_root.rb'],
                        ['subdir', 'test_subdir.rb']
                    assert_equal expected.to_set, app.each_test_file.to_set
                end
                it "enumerates *_test.rb files in test/lib" do
                    expected = touch_test_files \
                        ['root_test.rb'],
                        ['subdir', 'subdir_test.rb']
                    assert_equal expected.to_set, app.each_test_file.to_set
                end
                it "ignores files not matching the test pattern" do
                    touch_test_files \
                        ['root_test_root.rb'],
                        ['subdir', 'subdir.rb']
                    assert_equal [], app.each_test_file.to_a
                end
            end
        end

        describe "#self_file?" do
            it "returns true if the file's base path is the app dir" do
                assert app.self_file?(File.join(app_dir, "test", "file"))
            end
            it "returns false if the file's base path is not the app dir" do
                refute app.self_file?('/not/in/app/dir')
            end
        end

        describe "#each_test_file" do
            attr_reader :app
            before do
                @app = Roby::Application.new
                app.app_dir = make_tmpdir
                installer = Roby::Installer.new(app, quiet: true)
                installer.install
            end

            describe "included models" do
                attr_reader :task_m, :path

                before do
                    @task_m = Roby::Task.new_submodel(name: 'Test')
                    flexmock(app).should_receive(:test_file_for).
                        with(task_m).once.
                        and_return(@path = flexmock)
                    flexmock(app).should_receive(:test_file_for)
                end

                it "registers models using #test_file_for" do
                    assert_equal [[path, Set[task_m].to_set]], app.each_test_file.to_a
                end
                it "registers models that private_specializations? defined but are not specialized" do
                    flexmock(task_m).should_receive(:private_specialization?).explicitly.
                        and_return(false)
                    assert_equal [[path, Set[task_m].to_set]], app.each_test_file.to_a
                end
            end

            describe "ignored models" do
                attr_reader :task_m

                before do
                    @task_m = Roby::Task.new_submodel(name: 'Test')
                    flexmock(app).should_receive(:test_file_for).
                        with(task_m).never
                    flexmock(app).should_receive(:test_file_for)
                end

                it "ignores models that have no names" do
                    flexmock(task_m).should_receive(:name)
                    assert_equal [], app.each_test_file.to_a
                end

                it "ignores event models" do
                    flexmock(task_m).should_receive(:has_ancestor?).
                        with(Roby::Event).and_return(true)
                    assert_equal [], app.each_test_file.to_a
                end

                it "ignores private specializations" do
                    flexmock(task_m).should_receive(:private_specialization?).
                        explicitly.and_return(true)
                    assert_equal [], app.each_test_file.to_a
                end
            end

            describe "lib tests" do
                before do
                    flexmock(app).should_receive(:test_file_for)
                end

                def touch_test_files(*paths)
                    paths.map do |p|
                        full_p = File.join(app.app_dir, 'test', 'lib', *p)
                        FileUtils.mkdir_p File.dirname(full_p)
                        FileUtils.touch full_p
                        [full_p, Set.new]
                    end
                end

                it "enumerates test_*.rb files in test/lib" do
                    expected = touch_test_files \
                        ['test_root.rb'],
                        ['subdir', 'test_subdir.rb']
                    assert_equal expected.to_set, app.each_test_file.to_set
                end
                it "enumerates *_test.rb files in test/lib" do
                    expected = touch_test_files \
                        ['root_test.rb'],
                        ['subdir', 'subdir_test.rb']
                    assert_equal expected.to_set, app.each_test_file.to_set
                end
                it "ignores files not matching the test pattern" do
                    touch_test_files \
                        ['root_test_root.rb'],
                        ['subdir', 'subdir.rb']
                    assert_equal [], app.each_test_file.to_a
                end
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
                    parser.parse(['--set=a=10'])
                    assert_equal 10, Conf.a
                end
                it "parses words separated by dots as a chain of elements in the conf structure" do
                    parser.parse(['--set=a.deep.value=10'])
                    assert_equal 10, Conf.a.deep.value
                end
                it "parses the value in YAML" do
                    flexmock(YAML).should_receive(:load).
                        with('random_string').and_return(value = flexmock)
                    parser.parse(['--set=a.deep.value=random_string'])
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
                    log_dir = File.join(self.log_dir, 'test')
                    FileUtils.ln_s log_dir, current_path
                    error = assert_raises(ArgumentError) { app.log_current_dir }
                    assert_equal "#{current_path} points to #{log_dir}, which does not exist",
                        error.message
                end
                it "raises ArgumentError if the link does not point to a directory" do
                    FileUtils.touch(log_dir = File.join(self.log_dir, 'test'))
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
                assert_equal Array.new, app.log_read_metadata
            end
            it "returns an empty array if the log directory does not have an info.yml file" do
                app.log_dir = make_tmpdir
                assert_equal Array.new, app.log_read_metadata
            end
            it "returns the unmarshalled contents of the info.yml file" do
                app.log_dir = make_tmpdir
                File.open(File.join(app.log_dir, 'info.yml'), 'w') do |io|
                    YAML.dump(Hash['test' => true], io)
                end
                assert_equal Hash['test' => true], app.log_read_metadata
            end
        end
    end
end

