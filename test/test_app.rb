require 'roby/test/self'

class TC_Application < Minitest::Test
    def test_make_relative
        app = Roby::Application.new
        app.search_path = %w{/bla/blo /bli/blu}

        absolute_path = "/not/in/search/path"
        assert_equal(absolute_path, app.make_path_relative(absolute_path))

        absolute_path = "/bla/blo/config/file"
        assert_equal("config/file", app.make_path_relative(absolute_path))
    end
end

