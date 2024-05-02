# frozen_string_literal: true

require "roby"
require "roby/test/spec"
require "roby/test/minitest_plugin"
require "optparse"

Robot.logger.level = Logger::WARN

app = Roby.app
app.require_app_dir
app.public_logs = false
app.single = true
app.simulation = true
app.testing = true
app.auto_load_models = false

MetaRuby.keep_definition_location = false

list_tests = false
only_self = false
all = true
testrb_args = []
excluded_patterns = []
base_dir = File.join(Roby.app.app_dir, "test")
force_discovery = false
parser = OptionParser.new do |opt|
    opt.banner = "#{File.basename($0)} test [ROBY_OPTIONS] -- "\
                 "[MINITEST_OPTIONS] [TEST_FILES]"
    opt.on("--self", "only run tests that are present in this bundle") do |val|
        only_self = true
    end
    opt.on("--not-all", "run all the tests found in the bundle, regardless of whether "\
                        "they are loaded by the robot configuration") do |val|
        all = false
    end
    opt.on("--really-all", "load all models, and run all the tests "\
                           "found in the bundle") do |val|
        app.auto_load_models = true
        all = true
    end
    opt.on("--exclude PATTERN", String, "do not run files "\
           "matching this pattern") do |pattern|
        pattern = "**/#{pattern}" if pattern[0, 1] != "/"
        excluded_patterns << pattern
    end
    opt.on("--distributed", "access remote systems while setting up "\
                            "or running the tests") do |val|
        Roby.app.single = !val
    end
    opt.on("--list", "lists the test files that are executed, "\
                     "but does not execute them") do
        list_tests = true
    end
    opt.on("-l", "--live", "run tests in live mode") do |val|
        Roby.app.simulation = !val
    end
    opt.on("-k", "--keep-logs", "keep all logs") do
        Roby.app.public_logs = true
    end
    opt.on("--ui", "tell plugins and/or robot configurations to load their "\
                   "UI frameworks of choice. This does not imply --interactive") do
        Conf.ui = true
    end
    opt.on("-i", "--interactive", "allow user interaction during tests") do
        Roby.app.automatic_testing = false
    end
    opt.on("--coverage[=NAME]", String,
           "generate code coverage information. This autoloads "\
           "all files and task context models to get "\
           "a full coverage information") do |name|
        require "simplecov"
        SimpleCov.command_name name
        SimpleCov.start
    end
    opt.on("--base-dir DIR", "includes the directory on which the tests "\
                         "will be auto-discovered") do |dir|
        base_dir = dir
    end
    opt.on("--force-discovery",
           "call discover_test_files even if there are "\
           "explicit files on the command line") do
        force_discovery = true
    end
    opt.on "--help" do
        pp opt
        Minitest.run ["--help"]
        exit 0
    end
    Roby::Application.common_optparse_setup(opt)
end

minitest_path = $LOAD_PATH.resolve_feature_path("minitest").last
minitest_path_rx = Regexp.quote(File.dirname(minitest_path))
Roby.app.filter_out_patterns << Regexp.new("^#{minitest_path_rx}")

test_files = parser.parse(ARGV)
test_files.delete_if do |arg|
    if arg.start_with?("-")
        testrb_args << arg
        true
    end
end

if test_files.empty?
    MetaRuby.keep_definition_location = true
end

def discover_test_files(all:, only_self:, base_dir:)
    self_files, dependent_files = \
        Roby.app.discover_test_files(
            all: all, only_self: only_self, base_dir: base_dir
        ).map(&:first).partition { |f| Roby.app.self_file?(f) }

    self_files.sort + dependent_files.sort
end

exception = Roby.display_exception do
    Roby.app.setup
    if Roby.app.public_logs?
        STDOUT.puts "Test logs are saved in #{Roby.app.log_dir}"
    end
    passed =
        begin
            Roby.app.prepare

            test_files = test_files.flat_map do |file|
                next file unless file =~ /ROBOT/

                Roby.app.robot_configuration_names.map do |replacement|
                    resolved_file = File.join(Roby.app.app_dir, file.gsub("ROBOT", replacement))
                    resolved_file if File.file?(resolved_file)
                end.compact
            end

            test_files = test_files.flat_map do |arg|
                Dir.enum_for(:glob, arg).to_a
            end

            if test_files.empty?
                test_files = discover_test_files(all: all, only_self: only_self, base_dir: base_dir)
            elsif force_discovery
                test_files += discover_test_files(all: all, only_self: only_self, base_dir: base_dir)
            end

            if list_tests
                puts "Would load #{test_files.size} test files"
                test_files.each do |path|
                    puts "  #{path}"
                end

                all_existing_tests = Roby.app.find_dirs("test", order: :specific_first, all: !only_self).inject(Set.new) do |all, dir|
                    all.merge(Find.enum_for(:find, dir).find_all { |f| f =~ /\/test_.*\.rb$/ && File.file?(f) }.to_set)
                end
                not_run = (all_existing_tests - test_files.to_set)
                unless not_run.empty?
                    puts "\nWould NOT load #{not_run.size} tests"
                    not_run.to_a.sort.each do |not_loaded|
                        puts "  #{not_loaded}"
                    end
                end
                exit 0
            end

            test_files.sort.each do |arg|
                next if excluded_patterns.any? { |pattern| File.fnmatch?(pattern, arg) }

                require arg
            end

            Roby::Test::MinitestPlugin.register
            Minitest.run(testrb_args)
        ensure
            Roby.app.shutdown
            Roby.app.cleanup
        end

    SimpleCov.run_exit_tasks! if defined?(SimpleCov)
    exit(passed ? 0 : 1)
end
exit(exception ? 1 : 0)
