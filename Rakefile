# frozen_string_literal: true

puts ENV["PATH"]

require "bundler/gem_tasks"
require "rake/testtask"
require "yard"
require "yard/rake/yardoc_task"

ENV.delete("ROBY_PLUGIN_PATH")

task :default

TESTOPTS = ENV.delete("TESTOPTS") || ""
USE_JUNIT = (ENV["JUNIT"] == "1")
REPORT_DIR = ENV["REPORT_DIR"] || File.expand_path("test_reports", __dir__)

def minitest_set_options(test_task, name)
    minitest_options = []
    if USE_JUNIT
        minitest_options += [
            "--junit", "--junit-jenkins",
            "--junit-filename=#{REPORT_DIR}/#{name}.junit.xml"
        ]
    end

    minitest_args =
        if minitest_options.empty?
            ""
        else
            "\"#{minitest_options.join('" "')}\""
        end
    test_task.options = "#{TESTOPTS} #{minitest_args} -- --simplecov-name=#{name}"
end

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

Rake::TestTask.new("test:core") do |t|
    t.libs << "."
    t.libs << "lib"
    minitest_set_options(t, "core")
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

Rake::TestTask.new("test:interface:v1") do |t|
    t.libs << "."
    t.libs << "lib"
    minitest_set_options(t, "interface:v1")
    t.test_files = FileList["test/interface/v1/**/test_*.rb"]
    t.warning = false
end

Rake::TestTask.new("test:interface:v2") do |t|
    t.libs << "."
    t.libs << "lib"
    minitest_set_options(t, "interface:v2")
    t.test_files = FileList["test/interface/v2/**/test_*.rb"]
    t.warning = false
end

task "test" => "test:core"
task "test" => "test:interface:v2"

task "rubocop" do
    raise "rubocop failed" unless system(ENV["RUBOCOP_CMD"] || "rubocop")
end
task "test" => "rubocop" if ENV["RUBOCOP"] != "0"

# For backward compatibility with some scripts that expected hoe
task "gem" => "build"

UIFILES = %w[gui/relations_view/relations.ui
             gui/relations_view/relations_view.ui gui/stepping.ui].freeze
desc "generate all Qt UI files using rbuic4"
task :uic do
    rbuic = "rbuic4"
    rbuic = "/usr/lib/kde4/bin/rbuic4" if File.exist?("/usr/lib/kde4/bin/rbuic4")

    failed = false
    UIFILES.each do |file|
        file = "lib/roby/#{file}"
        unless system(rbuic, "-o", file.gsub(/\.ui$/, "_ui.rb"), file)
            STDERR.puts "Failed to generate #{file}"
            failed = true
        end
    end
    raise "uic generation failed" if failed
end
task "compile" => "uic"
task "test:core" => "uic" if has_gui

YARD::Rake::YardocTask.new
task "doc" => "yard"
