# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "yard"
require "yard/rake/yardoc_task"

task :default

has_gui =
    if ENV["TEST_DISABLE_GUI"] == "1"
        false
    else
        begin
            require "Qt"
            true
        rescue LoadError
            false
        end
    end

Rake::TestTask.new(:test) do |t|
    t.libs << "."
    t.libs << "lib"
    test_files = FileList["test/**/test_*.rb"]
    test_files = test_files.exclude("test/app/test_debug.rb") if RUBY_ENGINE != "ruby"
    if ENV["TEST_FAST"] == "1"
        test_files =
            test_files
            .exclude("test/cli/**/*.rb")
            .exclude("test/app/cucumber/test_controller.rb")
            .exclude("test/app/test_run.rb")
            .exclude("test/interface/async/test_interface.rb")
    end
    test_files = test_files.exclude("test/test_gui.rb") unless has_gui
    t.test_files = test_files
    t.warning = false
end

begin
    require "coveralls/rake/task"
    Coveralls::RakeTask.new
    task "test:coveralls" => ["test", "coveralls:push"]
rescue LoadError # rubocop:disable Lint/SuppressedException
end

# For backward compatibility with some scripts that expected hoe
task "gem" => "build"

UIFILES = %w[gui/relations_view/relations.ui
             gui/relations_view/relations_view.ui gui/stepping.ui].freeze
desc "generate all Qt UI files using rbuic4"
task :uic do
    rbuic = "rbuic4"
    rbuic = "/usr/lib/kde4/bin/rbuic4" if File.exist?("/usr/lib/kde4/bin/rbuic4")

    UIFILES.each do |file|
        file = "lib/roby/" + file
        unless system(rbuic, "-o", file.gsub(/\.ui$/, "_ui.rb"), file)
            STDERR.puts "Failed to generate #{file}"
        end
    end
end
task "compile" => "uic"

YARD::Rake::YardocTask.new
task "doc" => "yard"
