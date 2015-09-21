require 'roby/test/self'
require 'fakefs/safe'

describe Roby::Application do
    attr_reader :app, :app_dir
    before do
        @app = Roby::Application.new
        @app_dir = "/test/roby_app"
        FakeFS.activate!
        app.search_path = [app_dir]
        FileUtils.mkdir_p app_dir
    end

    after do
        FakeFS.deactivate!
        FakeFS::FileSystem.clear
    end

    describe "#make_relative" do
        before do
            app.search_path = %w{/bla/blo /bli/blu}
        end

        it "keeps absolute paths that are not in the search path as-is" do
            absolute_path = "/not/in/search/path"
            assert_equal(absolute_path, app.make_path_relative(absolute_path))
        end

        it "keeps absolute paths that are not present on disk paths that are in the search paths to return the shortest relative path" do
            absolute_path = "/bla/blo/config/file"
            assert_equal(absolute_path, app.make_path_relative(absolute_path))
        end

        it "converts paths that are present on disk and are prefixed by an entry in search_path" do
            absolute_path = "/bla/blo/config/file"
            FileUtils.mkdir_p File.dirname(absolute_path)
            File.open(absolute_path, 'w').close
            assert_equal("config/file", app.make_path_relative(absolute_path))
        end
    end

    describe "#test_file_for" do
        before do
            app.search_path = %w{/bla/blo /bla/blo/blu}
            FileUtils.mkdir_p "/bla/blo/models/compositions"
            FileUtils.touch "/bla/blo/models/compositions/file.rb"
            FileUtils.mkdir_p "/bla/blo/test/compositions"
            FileUtils.touch "/bla/blo/test/compositions/test_file.rb"
        end

        def assert_equal(expected, actual)
            assert expected == actual, "expected #{expected} to be equal to #{actual}"
        end

        it "returns a matching test file" do
            m = flexmock(definition_location: [['/bla/blo/models/compositions/file.rb', 120, :m]])
            assert_equal '/bla/blo/test/compositions/test_file.rb', app.test_file_for(m)
        end
        it "ignores entries not in the search path" do
            m = flexmock(definition_location: [['/bla/blo/models/compositions/file.rb', 120, :m]])
            app.search_path = []
            assert_equal nil, app.test_file_for(m)
        end
        it "ignores entries whose first element is not 'models'" do
            m = flexmock(definition_location: [['/bla/blo/models/compositions/file.rb', 120, :m]])
            app.search_path = ['/bla']
            assert_equal nil, app.test_file_for(m)
        end
        it "ignores entries that don't exist" do
            m = flexmock(definition_location: [['/bla/blo/models/compositions/file.rb', 120, :m]])
            FileUtils.rm_f "/bla/blo/test/compositions/test_file.rb"
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

