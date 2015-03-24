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

