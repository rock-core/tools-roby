# frozen_string_literal: true

require "roby/test/self"
require "lib/roby/custom_require.rb"

module Syskit
    describe CustomRequire do
        attr_reader :base_dir

        before do
            @base_dir = File.join(make_tmpdir, "app")
        end

        def create_file(*path)
            FileUtils.mkdir_p File.join(base_dir, *path[0..-2])
            FileUtils.touch   File.join(base_dir, *path)
        end

        it "resolves relative paths from registered roby applications" do
            create_file("models", "compositions", "file.rb")
            app.register_app(base_dir)
            relative_path = \
                File.join(File.basename(base_dir), "models", "compositions", "file.rb")
            full_path = \
                CustomRequire.resolve_from_apps(File.basename(base_dir), relative_path)

            refute_nil full_path
            assert_equal "#{base_dir}/models/compositions/file.rb", full_path
            assert_equal "#{base_dir}/models/compositions/file.rb",
                         Syskit::CustomRequire.resolve(relative_path)
        end

        it "resolves relative paths from roby search_path" do
            app.search_path = [base_dir]
            create_file("models", "file.rb")
            relative_path = "models/file.rb"
            full_path = CustomRequire.resolve_from_search_path(relative_path)

            refute_nil full_path
            assert_equal "#{base_dir}/models/file.rb", full_path
            assert_equal "#{base_dir}/models/file.rb",
                         Syskit::CustomRequire.resolve(relative_path)
        end

        it "does not modify relative paths when it fails to resolve it" do
            assert_equal "bundler",
                         Syskit::CustomRequire.resolve("bundler")
        end

        it "does not modify absolute paths" do
            create_file("file.rb")

            assert_equal "#{base_dir}/file.rb",
                         Syskit::CustomRequire.resolve("#{base_dir}/file.rb")
        end
    end
end
